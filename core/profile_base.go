package core

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/metacubex/mihomo/component/age"
	"github.com/metacubex/mihomo/config"
	"go.yaml.in/yaml/v3"
)

// What makes a profile large stays in the Core; the overlay the host sends
// back replaces every other section.
var profileBaseSections = []string{"proxies", "proxy-groups", "sub-rules"}

func handleGetProfileBase(params PathParams) (*ProfileBase, error) {
	defer scheduleLoadMemoryRelease()
	buf, err := os.ReadFile(params.Path)
	if err != nil {
		return nil, err
	}
	digest := sha256.Sum256(buf)
	raw, err := unmarshalRawConfig(buf)
	if err != nil {
		return nil, err
	}
	base := &ProfileBase{
		Digest:      hex.EncodeToString(digest[:]),
		MatchRules:  []string{},
		Proxies:     len(raw.Proxy),
		ProxyGroups: len(raw.ProxyGroup),
		Rules:       len(raw.Rule),
	}
	for _, rule := range raw.Rule {
		if isMatchRule(rule) {
			base.MatchRules = append(base.MatchRules, rule)
		}
	}
	raw.Proxy, raw.ProxyGroup, raw.Rule, raw.SubRules = nil, nil, nil, nil
	base.Config = raw
	return base, nil
}

func handleGetProfileOutbounds(params PathParams) (*ProfileOutbounds, error) {
	defer scheduleLoadMemoryRelease()
	buf, err := os.ReadFile(params.Path)
	if err != nil {
		return nil, err
	}
	raw, err := unmarshalRawConfig(buf)
	if err != nil {
		return nil, err
	}
	return &ProfileOutbounds{Proxies: outboundsOf(raw.Proxy), ProxyGroups: outboundsOf(raw.ProxyGroup), TLSFingerprints: tlsFingerprintsOf(raw.Proxy)}, nil
}

func tlsFingerprintsOf(proxies []map[string]any) map[string][]string {
	var pins map[string][]string
	for _, proxy := range proxies {
		kind, _ := proxy["type"].(string)
		if kind != "hysteria2" && kind != "tuic" {
			continue
		}
		host, _ := proxy["server"].(string)
		fingerprint, _ := proxy["fingerprint"].(string)
		fingerprint = strings.ToLower(strings.ReplaceAll(fingerprint, ":", ""))
		decoded, err := hex.DecodeString(fingerprint)
		if host == "" || err != nil || len(decoded) != sha256.Size {
			continue
		}
		if pins == nil {
			pins = make(map[string][]string)
		}
		host = strings.ToLower(strings.Trim(host, "[]"))
		duplicate := false
		for _, pin := range pins[host] {
			if pin == fingerprint {
				duplicate = true
				break
			}
		}
		if !duplicate {
			pins[host] = append(pins[host], fingerprint)
		}
	}
	return pins
}
func outboundsOf(mappings []map[string]any) []ProfileOutbound {
	outbounds := make([]ProfileOutbound, 0, len(mappings))
	for _, mapping := range mappings {
		name, _ := mapping["name"].(string)
		kind, _ := mapping["type"].(string)
		outbounds = append(outbounds, ProfileOutbound{Name: name, Type: kind})
	}
	return outbounds
}

// The merged config goes to the spill directory, so the host reads it as text
// and never decodes it.
func handleBuildProfile(base *SetupBase) (string, error) {
	defer scheduleLoadMemoryRelease()
	document, err := mergeProfileBase(base)
	if err != nil {
		return "", err
	}
	dir, err := makeSpilledResponseDir()
	if err != nil {
		return "", err
	}
	path, err := writeDocumentFile(dir, "*.yaml", document)
	if err != nil {
		return "", err
	}
	scheduleReclaimOwnership()
	return path, nil
}

// Mirrors Rule.parse in Dart, which reads the type from the first field.
func isMatchRule(rule string) bool {
	kind, _, _ := strings.Cut(rule, ",")
	return strings.EqualFold(strings.TrimSpace(kind), "MATCH")
}

func loadConfigWithBase(base *SetupBase, configPath string) (*config.Config, error) {
	cfg, _, err := loadConfigWithBaseRaw(base, configPath)
	return cfg, err
}

func loadConfigWithBaseRaw(base *SetupBase, configPath string) (*config.Config, *config.RawConfig, error) {
	document, err := mergeProfileBase(base)
	if err != nil {
		return nil, nil, err
	}
	raw := config.DefaultRawConfig()
	if err := document.Decode(raw); err != nil {
		return nil, nil, err
	}
	// The overlay's rules (the user's own, first) stay ahead of the AI rules.
	var overlay struct {
		Rules []string `yaml:"rules"`
	}
	_ = yaml.Unmarshal([]byte(base.Overlay), &overlay)
	if err := enhanceProfileDocument(document, raw, len(overlay.Rules)); err != nil {
		return nil, nil, err
	}
	tmpPath, err := writeDocumentFile(filepath.Dir(configPath), ".config-*.yaml", document)
	if err != nil {
		return nil, nil, err
	}
	cfg, err := config.ParseRawConfig(raw)
	if err != nil {
		_ = os.Remove(tmpPath)
		return nil, nil, err
	}
	if err := renameReplacing(tmpPath, configPath); err != nil {
		_ = os.Remove(tmpPath)
		return nil, nil, err
	}
	scheduleReclaimOwnership()
	return withPlatformLimits(cfg), raw, nil
}

func mergeProfileBase(base *SetupBase) (*yaml.Node, error) {
	buf, err := os.ReadFile(base.Path)
	if err != nil {
		return nil, err
	}
	if buf, err = age.DecryptBytes(buf); err != nil {
		return nil, fmt.Errorf("decrypt config error: %w", err)
	}
	retag := bytes.Contains(buf, []byte("short-id")) || strings.Contains(base.Overlay, "short-id")
	var profileDocument, overlayDocument yaml.Node
	if err := yaml.Unmarshal(buf, &profileDocument); err != nil {
		return nil, err
	}
	if err := yaml.Unmarshal([]byte(base.Overlay), &overlayDocument); err != nil {
		return nil, err
	}
	for _, document := range []*yaml.Node{&profileDocument, &overlayDocument} {
		if err := validateYamlAliases(document); err != nil {
			return nil, err
		}
	}
	profile, err := documentMapping(&profileDocument)
	if err != nil {
		return nil, err
	}
	root, err := documentMapping(&overlayDocument)
	if err != nil {
		return nil, err
	}
	for _, key := range profileBaseSections {
		if value := mappingValue(profile, key); value != nil {
			setMappingValue(root, key, value)
		}
	}
	rules, err := appendRules(mappingValue(root, "rules"), mappingValue(profile, "rules"))
	if err != nil {
		return nil, err
	}
	if rules != nil {
		setMappingValue(root, "rules", rules)
	}
	if retag {
		retagShortIDs(root)
	}
	return &yaml.Node{Kind: yaml.DocumentNode, Content: []*yaml.Node{root}}, nil
}

func cloneYamlNode(node *yaml.Node) *yaml.Node {
	cloned := *node
	cloned.Anchor = ""
	if len(node.Content) > 0 {
		cloned.Content = append([]*yaml.Node(nil), node.Content...)
	}
	return &cloned
}

func enhanceProfileDocument(document *yaml.Node, raw *config.RawConfig, userRules int) error {
	if !vpsSmartEnabled.Load() {
		return nil
	}
	groupCount, ruleCount := len(raw.ProxyGroup), len(raw.Rule)
	res := vps2vpnEnhanceResult(raw, userRules)
	if len(res.fingerprinted) == 0 && res.addedGroups == 0 && res.addedRules == 0 {
		return nil
	}
	root, err := documentMapping(document)
	if err != nil {
		return err
	}
	if len(res.fingerprinted) > 0 {
		if proxies := resolveAlias(mappingValue(root, "proxies")); proxies != nil && proxies.Kind == yaml.SequenceNode {
			proxies = cloneYamlNode(proxies)
			setMappingValue(root, "proxies", proxies)
			for _, i := range res.fingerprinted {
				if i < 0 || i >= len(proxies.Content) {
					continue
				}
				node := resolveAlias(proxies.Content[i])
				if node == nil || node.Kind != yaml.MappingNode {
					continue
				}
				cloned := cloneYamlNode(node)
				setMappingValue(cloned, "client-fingerprint", &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: "chrome"})
				proxies.Content[i] = cloned
			}
		}
	}
	if res.addedGroups > 0 {
		groups := resolveAlias(mappingValue(root, "proxy-groups"))
		if groups == nil || isNull(groups) || groups.Kind != yaml.SequenceNode {
			groups = &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq"}
		} else {
			groups = cloneYamlNode(groups)
		}
		setMappingValue(root, "proxy-groups", groups)
		if res.selectIndex >= 0 && res.selectIndex < len(groups.Content) && res.selectIndex < groupCount {
			if groupNode := resolveAlias(groups.Content[res.selectIndex]); groupNode != nil && groupNode.Kind == yaml.MappingNode {
				var members yaml.Node
				if err := members.Encode(raw.ProxyGroup[res.selectIndex]["proxies"]); err != nil {
					return err
				}
				cloned := cloneYamlNode(groupNode)
				setMappingValue(cloned, "proxies", &members)
				groups.Content[res.selectIndex] = cloned
			}
		}
		for _, group := range raw.ProxyGroup[groupCount:] {
			var node yaml.Node
			if err := node.Encode(group); err != nil {
				return err
			}
			groups.Content = append(groups.Content, &node)
		}
	}
	if res.addedRules > 0 {
		rules := resolveAlias(mappingValue(root, "rules"))
		if rules == nil || isNull(rules) || rules.Kind != yaml.SequenceNode {
			rules = &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq"}
		} else {
			rules = cloneYamlNode(rules)
		}
		setMappingValue(root, "rules", rules)
		at := max(0, min(userRules, len(rules.Content)))
		rawAt := max(0, min(userRules, ruleCount))
		content := make([]*yaml.Node, 0, len(rules.Content)+res.addedRules)
		content = append(content, rules.Content[:at]...)
		for _, rule := range raw.Rule[rawAt : rawAt+res.addedRules] {
			content = append(content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: rule})
		}
		rules.Content = append(content, rules.Content[at:]...)
	}
	return nil
}

const maxExpandedYamlNodes = 2_000_000

func validateYamlAliases(root *yaml.Node) error {
	const (
		visiting uint8 = 1
		visited  uint8 = 2
	)
	states := map[*yaml.Node]uint8{}
	sizes := map[*yaml.Node]int{}
	var visit func(*yaml.Node) (int, error)
	visit = func(node *yaml.Node) (int, error) {
		if node == nil {
			return 0, nil
		}
		if node.Kind == yaml.AliasNode {
			if node.Alias == nil {
				return 1, nil
			}
			return visit(node.Alias)
		}
		if node.Anchor != "" {
			switch states[node] {
			case visiting:
				return 0, fmt.Errorf("line %d: cyclic YAML alias %q", node.Line, node.Anchor)
			case visited:
				return sizes[node], nil
			}
			states[node] = visiting
		}
		total := 1
		for _, child := range node.Content {
			n, err := visit(child)
			if err != nil {
				return 0, err
			}
			if n > maxExpandedYamlNodes-total {
				return 0, fmt.Errorf("line %d: YAML alias expansion exceeds %d nodes", node.Line, maxExpandedYamlNodes)
			}
			total += n
		}
		if node.Anchor != "" {
			states[node] = visited
			sizes[node] = total
		}
		return total, nil
	}
	_, err := visit(root)
	return err
}

func documentMapping(document *yaml.Node) (*yaml.Node, error) {
	node := document
	if node.Kind == yaml.DocumentNode && len(node.Content) > 0 {
		node = resolveAlias(node.Content[0])
	}
	switch {
	case node.Kind == yaml.MappingNode:
		return node, nil
	case node.Kind == 0, node.Kind == yaml.DocumentNode, isNull(node):
		return &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}, nil
	}
	return nil, fmt.Errorf("line %d: a config must be a mapping", node.Line)
}

// A key the mapping lacks is looked up in its merge keys, as the decoder does.
func mappingValue(mapping *yaml.Node, key string) *yaml.Node {
	var sources []*yaml.Node
	for i := 0; i+1 < len(mapping.Content); i += 2 {
		name, value := mapping.Content[i], mapping.Content[i+1]
		if name.Kind != yaml.ScalarNode {
			continue
		}
		if name.ShortTag() == "!!merge" {
			sources = append(sources, value)
		} else if name.Value == key {
			return value
		}
	}
	for _, source := range sources {
		source = resolveAlias(source)
		candidates := []*yaml.Node{source}
		if source.Kind == yaml.SequenceNode {
			candidates = source.Content
		}
		for _, candidate := range candidates {
			if candidate = resolveAlias(candidate); candidate.Kind == yaml.MappingNode {
				if value := mappingValue(candidate, key); value != nil {
					return value
				}
			}
		}
	}
	return nil
}

func setMappingValue(mapping *yaml.Node, key string, value *yaml.Node) {
	for i := 0; i+1 < len(mapping.Content); i += 2 {
		if name := mapping.Content[i]; name.Kind == yaml.ScalarNode && name.Value == key {
			mapping.Content[i+1] = value
			return
		}
	}
	mapping.Content = append(
		mapping.Content,
		&yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: key},
		value,
	)
}

// The overlay's rules are the ones the host adds in front of the profile's.
func appendRules(added, profile *yaml.Node) (*yaml.Node, error) {
	if profile == nil {
		return nil, nil
	}
	added, profile = resolveAlias(added), resolveAlias(profile)
	if added == nil || isNull(added) || (added.Kind == yaml.SequenceNode && len(added.Content) == 0) {
		return profile, nil
	}
	if isNull(profile) {
		return added, nil
	}
	if added.Kind != yaml.SequenceNode || profile.Kind != yaml.SequenceNode {
		return nil, fmt.Errorf("line %d: rules must be a list", profile.Line)
	}
	content := make([]*yaml.Node, 0, len(added.Content)+len(profile.Content))
	content = append(append(content, added.Content...), profile.Content...)
	return &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq", Content: content}, nil
}

func resolveAlias(node *yaml.Node) *yaml.Node {
	for node != nil && node.Kind == yaml.AliasNode && node.Alias != nil {
		node = node.Alias
	}
	return node
}

func isNull(node *yaml.Node) bool {
	return node.Kind == yaml.ScalarNode && node.ShortTag() == "!!null"
}

// config.yaml is read again without this process: by the Android service
// starting on its own and by mihomo's own reload through the controller.
func writeConfigDocument(path string, document *yaml.Node) error {
	temporary, err := writeDocumentFile(filepath.Dir(path), ".config-*.yaml", document)
	if err != nil {
		return err
	}
	if err := renameReplacing(temporary, path); err != nil {
		_ = os.Remove(temporary)
		return err
	}
	scheduleReclaimOwnership()
	return nil
}

func writeDocumentFile(dir, pattern string, document *yaml.Node) (string, error) {
	inlineAliases(document)
	file, err := os.CreateTemp(dir, pattern)
	if err != nil {
		return "", err
	}
	if err := preparePrivateFile(file); err != nil {
		_ = file.Close()
		_ = os.Remove(file.Name())
		return "", err
	}
	writer := bufio.NewWriterSize(file, 1<<20)
	err = errors.Join(
		encodeConfigMapping(writer, document.Content[0]),
		writer.Flush(),
		file.Close(),
	)
	if err != nil {
		_ = os.Remove(file.Name())
		return "", err
	}
	return file.Name(), nil
}

// One Encode call keeps every event it emitted until it returns, several times
// the size of a large profile, so a long top-level list goes out in slices.
const encodeSliceLength = 4096

// The mapping is drained as it is written, so the parse that follows does not
// share the heap with the whole tree.
func encodeConfigMapping(w io.Writer, mapping *yaml.Node) error {
	for i := 0; i+1 < len(mapping.Content); i += 2 {
		key, value := mapping.Content[i], mapping.Content[i+1]
		mapping.Content[i+1] = nil
		if value.Kind != yaml.SequenceNode || len(value.Content) <= encodeSliceLength {
			pair := &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map", Content: []*yaml.Node{key, value}}
			if err := encodeYamlPiece(w, pair, nil); err != nil {
				return err
			}
			continue
		}
		plainKey := *key
		plainKey.LineComment = ""
		plainKey.FootComment = ""
		if err := encodeYamlPiece(w, &plainKey, []byte(":\n")); err != nil {
			return err
		}
		for start := 0; start < len(value.Content); start += encodeSliceLength {
			items := value.Content[start:min(start+encodeSliceLength, len(value.Content))]
			slice := &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq", Content: items}
			if err := encodeYamlPiece(w, slice, nil); err != nil {
				return err
			}
		}
	}
	return nil
}

// Each piece is a document of its own; an end marker left between two of them
// would end config.yaml there.
func encodeYamlPiece(w io.Writer, node *yaml.Node, suffix []byte) error {
	var buffer bytes.Buffer
	encoder := yaml.NewEncoder(&buffer)
	encoder.SetIndent(2)
	if err := errors.Join(encoder.Encode(node), encoder.Close()); err != nil {
		return err
	}
	piece := bytes.TrimSuffix(buffer.Bytes(), []byte("...\n"))
	if suffix != nil {
		piece = append(bytes.TrimSuffix(piece, []byte("\n")), suffix...)
	}
	_, err := w.Write(piece)
	return err
}

// An anchor may sit in a section the overlay replaced, so every alias is
// written out in full, as the host's own encoder always did.
func inlineAliases(root *yaml.Node) {
	visited := map[*yaml.Node]struct{}{}
	var walk func(node *yaml.Node)
	walk = func(node *yaml.Node) {
		if _, seen := visited[node]; seen {
			return
		}
		if node.Anchor != "" {
			visited[node] = struct{}{}
			node.Anchor = ""
		}
		for i, child := range node.Content {
			child = resolveAlias(child)
			node.Content[i] = child
			walk(child)
		}
	}
	walk(root)
}
