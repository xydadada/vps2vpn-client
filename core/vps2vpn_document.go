package core

import "go.yaml.in/yaml/v3"

type vpsEnhancement struct {
	fingerprints []int
	selector     int
	groups       []map[string]any
	ruleStart    int
	rules        []string
}

func yamlString(value string) *yaml.Node {
	return &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: value}
}

func (changes vpsEnhancement) apply(document *yaml.Node) error {
	root, err := documentMapping(document)
	if err != nil {
		return err
	}
	if len(changes.fingerprints) > 0 {
		proxies := resolveAlias(mappingValue(root, "proxies"))
		for _, index := range changes.fingerprints {
			proxy := resolveAlias(proxies.Content[index])
			setMappingValue(proxy, "client-fingerprint", yamlString("chrome"))
		}
	}
	groups := resolveAlias(mappingValue(root, "proxy-groups"))
	if changes.selector >= 0 {
		selector := resolveAlias(groups.Content[changes.selector])
		members := resolveAlias(mappingValue(selector, "proxies"))
		content := []*yaml.Node{yamlString(vpsSmartGroup)}
		if members != nil && members.Kind == yaml.SequenceNode {
			content = append(content, members.Content...)
		}
		setMappingValue(selector, "proxies", &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq", Content: content})
	}
	if len(changes.groups) > 0 {
		if groups == nil || isNull(groups) {
			groups = &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq"}
			setMappingValue(root, "proxy-groups", groups)
		}
		for _, group := range changes.groups {
			var node yaml.Node
			if err := node.Encode(group); err != nil {
				return err
			}
			groups.Content = append(groups.Content, &node)
		}
	}
	if len(changes.rules) > 0 {
		rules := resolveAlias(mappingValue(root, "rules"))
		if rules == nil || isNull(rules) {
			rules = &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq"}
			setMappingValue(root, "rules", rules)
		}
		content := make([]*yaml.Node, 0, len(rules.Content)+len(changes.rules))
		content = append(content, rules.Content[:changes.ruleStart]...)
		for _, rule := range changes.rules {
			content = append(content, yamlString(rule))
		}
		rules.Content = append(content, rules.Content[changes.ruleStart:]...)
	}
	return nil
}
