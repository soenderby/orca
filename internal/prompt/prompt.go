// Package prompt renders the ORCA_PROMPT template placeholders.
package prompt

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
)

var placeholderPattern = regexp.MustCompile(`__[A-Z0-9_]+__`)

var knownPlaceholders = map[string]struct{}{
	"__AGENT_NAME__":                 {},
	"__ISSUE_ID__":                   {},
	"__ASSIGNED_ISSUE_ID__":          {},
	"__ASSIGNMENT_MODE__":            {},
	"__WORKTREE__":                   {},
	"__RUN_SUMMARY_PATH__":           {},
	"__RUN_SUMMARY_JSON__":           {},
	"__SUMMARY_JSON_PATH__":          {},
	"__PRIMARY_REPO__":               {},
	"__ORCA_PRIMARY_REPO__":          {},
	"__WITH_LOCK_PATH__":             {},
	"__ORCA_WITH_LOCK_PATH__":        {},
	"__QUEUE_READ_MAIN_PATH__":       {},
	"__ORCA_QUEUE_READ_MAIN_PATH__":  {},
	"__QUEUE_WRITE_MAIN_PATH__":      {},
	"__ORCA_QUEUE_WRITE_MAIN_PATH__": {},
	"__MERGE_MAIN_PATH__":            {},
	"__ORCA_MERGE_MAIN_PATH__":       {},
}

// ValidateTemplate checks that a prompt template only uses supported
// placeholders.
func ValidateTemplate(template string) error {
	unknown := unknownPlaceholders(template)
	if len(unknown) > 0 {
		return fmt.Errorf("unknown placeholders: %s", strings.Join(unknown, ","))
	}
	return nil
}

// Render substitutes known placeholders in template.
//
// Unknown placeholders are treated as an error to fail fast on template drift
// and typographical mistakes. Known placeholders with no value are replaced
// with an empty string.
func Render(template string, values map[string]string) (string, error) {
	if template == "" {
		return "", nil
	}

	if err := ValidateTemplate(template); err != nil {
		return "", err
	}

	if values == nil {
		values = map[string]string{}
	}

	rendered := placeholderPattern.ReplaceAllStringFunc(template, func(token string) string {
		if v, ok := values[token]; ok {
			return v
		}
		inner := token[2 : len(token)-2]
		if v, ok := values[inner]; ok {
			return v
		}
		return ""
	})

	return rendered, nil
}

func unknownPlaceholders(template string) []string {
	matches := placeholderPattern.FindAllString(template, -1)
	if len(matches) == 0 {
		return nil
	}

	seen := map[string]struct{}{}
	unknown := make([]string, 0)
	for _, token := range matches {
		if _, known := knownPlaceholders[token]; known {
			continue
		}
		if _, ok := seen[token]; ok {
			continue
		}
		seen[token] = struct{}{}
		unknown = append(unknown, token)
	}
	sort.Strings(unknown)
	return unknown
}
