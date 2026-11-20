use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use super::PAC_PATH;

const MAX_REQUEST_BYTES: usize = 16 * 1024;
const MAX_CONCURRENT_REQUESTS: usize = 32;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);

static SCRIPT: Mutex<String> = Mutex::new(String::new());
static REVISION: AtomicU64 = AtomicU64::new(0);

/// Serves `script` and returns its URL. The listener stays up for the life of
/// the process; each call gets a fresh query so systems that cache a PAC file
/// by URL fetch the new script.
pub fn serve(script: String) -> Option<String> {
    *SCRIPT
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = script;
    let address = (*listener_address())?;
    let revision = REVISION.fetch_add(1, Ordering::SeqCst);
    Some(format!("http://{address}{PAC_PATH}?v={revision}"))
}

fn listener_address() -> &'static Option<SocketAddr> {
    static ADDRESS: OnceLock<Option<SocketAddr>> = OnceLock::new();
    ADDRESS.get_or_init(|| {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).ok()?;
        let address = listener.local_addr().ok()?;
        std::thread::Builder::new()
            .name("system-proxy-pac".into())
            .spawn(move || accept(listener))
            .ok()?;
        Some(address)
    })
}

fn accept(listener: TcpListener) {
    let active = Arc::new(AtomicUsize::new(0));
    for stream in listener.incoming() {
        let Ok(stream) = stream else {
            std::thread::sleep(Duration::from_millis(100));
            continue;
        };
        let Some(slot) = RequestSlot::acquire(&active) else {
            continue;
        };
        let deadline = Instant::now() + REQUEST_TIMEOUT;
        let _ = std::thread::Builder::new()
            .name("system-proxy-pac-request".into())
            .spawn(move || {
                let _slot = slot;
                respond(stream, deadline);
            });
    }
}

struct RequestSlot(Arc<AtomicUsize>);

impl RequestSlot {
    fn acquire(active: &Arc<AtomicUsize>) -> Option<Self> {
        active
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |count| {
                (count < MAX_CONCURRENT_REQUESTS).then_some(count + 1)
            })
            .ok()
            .map(|_| Self(Arc::clone(active)))
    }
}

impl Drop for RequestSlot {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::Relaxed);
    }
}

fn respond(mut stream: TcpStream, deadline: Instant) {
    let Some(head) = read_head(&mut stream, deadline) else {
        return;
    };
    let script = SCRIPT
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .clone();
    let _ = write_before_deadline(&mut stream, &response(&head, &script), deadline);
}

fn read_head(stream: &mut TcpStream, deadline: Instant) -> Option<String> {
    let mut head = Vec::new();
    let mut buffer = [0; 1024];
    while !head.windows(4).any(|window| window == b"\r\n\r\n") {
        let remaining = deadline.checked_duration_since(Instant::now())?;
        stream.set_read_timeout(Some(remaining)).ok()?;
        let read = stream.read(&mut buffer).ok()?;
        if read == 0 || head.len() + read > MAX_REQUEST_BYTES {
            return None;
        }
        head.extend_from_slice(&buffer[..read]);
    }
    Some(String::from_utf8_lossy(&head).into_owned())
}

fn write_before_deadline(
    stream: &mut TcpStream,
    mut bytes: &[u8],
    deadline: Instant,
) -> Option<()> {
    while !bytes.is_empty() {
        let remaining = deadline.checked_duration_since(Instant::now())?;
        stream.set_write_timeout(Some(remaining)).ok()?;
        let written = stream.write(bytes).ok()?;
        if written == 0 {
            return None;
        }
        bytes = &bytes[written..];
    }
    Some(())
}

fn response(head: &str, script: &str) -> Vec<u8> {
    let mut parts = head.lines().next().unwrap_or_default().split(' ');
    let method = parts.next().unwrap_or_default();
    let path = parts.next().unwrap_or_default();
    let path = path.split_once('?').map_or(path, |(path, _)| path);
    let (status, body) = match method {
        "GET" | "HEAD" if path == PAC_PATH && !script.is_empty() => ("200 OK", script),
        "GET" | "HEAD" => ("404 Not Found", ""),
        _ => ("405 Method Not Allowed", ""),
    };
    let mut response = format!(
        "HTTP/1.1 {status}\r\n\
         Content-Type: application/x-ns-proxy-autoconfig\r\n\
         Content-Length: {}\r\n\
         Cache-Control: no-store\r\n\
         Connection: close\r\n\r\n",
        body.len()
    )
    .into_bytes();
    if method != "HEAD" {
        response.extend_from_slice(body.as_bytes());
    }
    response
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(bytes: Vec<u8>) -> String {
        String::from_utf8(bytes).unwrap()
    }

    fn connection() -> (TcpStream, TcpStream) {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        (listener.accept().unwrap().0, client)
    }

    #[test]
    fn limits_active_requests_and_returns_capacity_when_a_request_ends() {
        let active = Arc::new(AtomicUsize::new(0));
        let mut slots: Vec<_> = (0..MAX_CONCURRENT_REQUESTS)
            .map(|_| RequestSlot::acquire(&active).unwrap())
            .collect();
        assert!(RequestSlot::acquire(&active).is_none());
        slots.pop();
        assert!(RequestSlot::acquire(&active).is_some());
        drop(slots);
        assert_eq!(active.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn rejects_a_header_that_exceeds_the_size_limit() {
        let (mut server, mut client) = connection();
        client.write_all(&vec![b'x'; MAX_REQUEST_BYTES + 1]).unwrap();
        assert!(read_head(&mut server, Instant::now() + REQUEST_TIMEOUT).is_none());
    }

    #[test]
    fn a_slow_header_cannot_extend_the_request_deadline() {
        let (mut server, mut client) = connection();
        let writer = std::thread::spawn(move || {
            for _ in 0..100 {
                if client.write_all(b"x").is_err() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        });
        let started = Instant::now();
        assert!(read_head(&mut server, started + Duration::from_millis(100)).is_none());
        assert!(started.elapsed() < Duration::from_secs(1));
        drop(server);
        writer.join().unwrap();
    }

    #[test]
    fn a_peer_that_does_not_read_cannot_retain_a_worker_past_the_deadline() {
        let (mut server, client) = connection();
        #[cfg(windows)]
        {
            use std::os::windows::io::AsRawSocket;
            use windows_sys::Win32::Networking::WinSock::{
                setsockopt, SOL_SOCKET, SO_RCVBUF, SO_SNDBUF,
            };

            let size: i32 = 4096;
            for (socket, option) in [(&server, SO_SNDBUF), (&client, SO_RCVBUF)] {
                let result = unsafe {
                    setsockopt(
                        socket.as_raw_socket() as usize,
                        SOL_SOCKET,
                        option,
                        (&size as *const i32).cast(),
                        std::mem::size_of_val(&size) as i32,
                    )
                };
                assert_eq!(result, 0);
            }
        }
        let _client = client;
        server.set_nonblocking(true).unwrap();
        let fill_started = Instant::now();
        let chunk = [b'x'; 64 * 1024];
        let mut queued = 0;
        loop {
            match server.write(&chunk) {
                Ok(0) => panic!("connection closed while filling the send buffer"),
                Ok(written) => queued += written,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(error) => panic!("could not fill the send buffer: {error}"),
            }
            assert!(
                queued <= 64 * 1024 * 1024 && fill_started.elapsed() < Duration::from_secs(2),
                "the non-reading peer never applied backpressure after {queued} bytes",
            );
        }
        server.set_nonblocking(false).unwrap();
        let payload = vec![b'x'; 16 * 1024 * 1024];
        let started = Instant::now();
        assert!(write_before_deadline(
            &mut server,
            &payload,
            started + Duration::from_millis(100),
        )
        .is_none());
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn accepts_a_complete_header_before_the_deadline() {
        let (mut server, mut client) = connection();
        let head = "GET /flclash.pac HTTP/1.1\r\nHost: localhost\r\n\r\n";
        client.write_all(head.as_bytes()).unwrap();
        assert_eq!(
            read_head(&mut server, Instant::now() + REQUEST_TIMEOUT).as_deref(),
            Some(head),
        );
    }

    #[test]
    fn serves_the_script_at_its_path_whatever_the_query() {
        let reply = text(response(
            "GET /flclash.pac?v=3 HTTP/1.1\r\n",
            "function x() {}",
        ));
        assert!(reply.starts_with("HTTP/1.1 200 OK\r\n"));
        assert!(reply.contains("Content-Length: 15\r\n"));
        assert!(reply.ends_with("\r\n\r\nfunction x() {}"));
    }

    #[test]
    fn answers_head_without_a_body() {
        let reply = text(response("HEAD /flclash.pac HTTP/1.1\r\n", "abc"));
        assert!(reply.contains("Content-Length: 3\r\n"));
        assert!(reply.ends_with("\r\n\r\n"));
    }

    #[test]
    fn refuses_other_paths_methods_and_an_unset_script() {
        assert!(text(response("GET / HTTP/1.1\r\n", "abc")).starts_with("HTTP/1.1 404"));
        assert!(text(response("GET /flclash.pac HTTP/1.1\r\n", "")).starts_with("HTTP/1.1 404"));
        assert!(text(response("POST /flclash.pac HTTP/1.1\r\n", "abc")).starts_with("HTTP/1.1 405"));
    }

    #[test]
    fn serves_the_latest_script_over_loopback() {
        let first = serve("first".into()).unwrap();
        let second = serve("second".into()).unwrap();
        assert_ne!(first, second);
        let address = second
            .strip_prefix("http://")
            .and_then(|rest| rest.split_once('/'))
            .map(|(address, _)| address.to_owned())
            .unwrap();
        let mut stream = TcpStream::connect(address).unwrap();
        stream
            .write_all(b"GET /flclash.pac HTTP/1.1\r\nHost: x\r\n\r\n")
            .unwrap();
        let mut reply = String::new();
        stream.read_to_string(&mut reply).unwrap();
        assert!(reply.ends_with("\r\n\r\nsecond"));
    }
}
