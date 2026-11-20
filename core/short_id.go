package core

import (
	"bytes"
	"fmt"

	"github.com/metacubex/mihomo/component/age"
	"github.com/metacubex/mihomo/config"
	"go.yaml.in/yaml/v3"
)

// mihomo decodes an unquoted REALITY short-id as a YAML number (0123 is 83, 00
// is 0); the scalar keeps its literal text, so retagging it restores the id.
func unmarshalRawConfig(buf []byte) (*config.RawConfig, error) {
	var err error
	if buf, err = age.DecryptBytes(buf); err != nil {
		return nil, fmt.Errorf("decrypt config error: %w", err)
	}
	if !bytes.Contains(buf, []byte("short-id")) {
		return config.UnmarshalRawConfig(buf)
	}
	var document yaml.Node
	if yaml.Unmarshal(buf, &document) != nil {
		return config.UnmarshalRawConfig(buf)
	}
	if err := validateYamlAliases(&document); err != nil {
		return nil, err
	}
	if !retagShortIDs(&document) {
		return config.UnmarshalRawConfig(buf)
	}
	rawConfig := config.DefaultRawConfig()
	if err := document.Decode(rawConfig); err != nil {
		return nil, err
	}
	return rawConfig, nil
}

func retagShortIDs(node *yaml.Node) bool {
	return retagShortIDsWithAliases(node, map[*yaml.Node]bool{})
}

func retagShortIDsWithAliases(node *yaml.Node, aliases map[*yaml.Node]bool) bool {
	if node == nil {
		return false
	}
	if node.Kind == yaml.AliasNode && node.Alias != nil {
		if aliases[node.Alias] {
			return false
		}
		aliases[node.Alias] = true
		return retagShortIDsWithAliases(node.Alias, aliases)
	}
	retagged := false
	if node.Kind == yaml.MappingNode {
		for i := 0; i+1 < len(node.Content); i += 2 {
			if node.Content[i].Value == "short-id" {
				retagged = retagNumber(&node.Content[i+1]) || retagged
			}
		}
	}
	for _, child := range node.Content {
		retagged = retagShortIDsWithAliases(child, aliases) || retagged
	}
	return retagged
}

func retagNumber(slot **yaml.Node) bool {
	return retagNumberWithAliases(slot, map[*yaml.Node]bool{})
}

func retagNumberWithAliases(slot **yaml.Node, aliases map[*yaml.Node]bool) bool {
	node := *slot
	if node == nil {
		return false
	}
	switch node.Kind {
	case yaml.AliasNode:
		if node.Alias == nil || aliases[node.Alias] {
			return false
		}
		aliases[node.Alias] = true
		defer delete(aliases, node.Alias)
		target := node.Alias
		for target.Kind == yaml.AliasNode {
			if target.Alias == nil || aliases[target.Alias] {
				return false
			}
			aliases[target.Alias] = true
			defer delete(aliases, target.Alias)
			target = target.Alias
		}
		switch target.Kind {
		case yaml.ScalarNode:
			if target.Style == 0 && (target.Tag == "!!int" || target.Tag == "!!float") {
				cloned := *target
				cloned.Anchor = ""
				cloned.Tag = "!!str"
				*slot = &cloned
				return true
			}
		case yaml.SequenceNode:
			cloned := *target
			cloned.Anchor = ""
			cloned.Content = append([]*yaml.Node(nil), target.Content...)
			retagged := false
			for i := range cloned.Content {
				retagged = retagNumberWithAliases(&cloned.Content[i], aliases) || retagged
			}
			if retagged {
				*slot = &cloned
			}
			return retagged
		}
	case yaml.ScalarNode:
		if node.Style == 0 && (node.Tag == "!!int" || node.Tag == "!!float") {
			node.Tag = "!!str"
			return true
		}
	case yaml.SequenceNode:
		retagged := false
		for i := range node.Content {
			retagged = retagNumberWithAliases(&node.Content[i], aliases) || retagged
		}
		return retagged
	}
	return false
}
