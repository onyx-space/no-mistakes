package config

import (
	"strings"
	"testing"
)

// TestEffectiveRepoConfig_PRInstructionsTrustedOnly proves the pull-request
// content policy is honored only from the trusted default-branch copy,
// exactly like document.instructions and test.instructions.
//
// The stakes and the direction are the same as those two: pr.instructions is
// injected into the prompt of the agent that drafts the body reviewing the
// pushed branch, so a pushed branch that could set it could write its own
// pull request's visible content.
func TestEffectiveRepoConfig_PRInstructionsTrustedOnly(t *testing.T) {
	pushed := &RepoConfig{PR: PRRaw{Instructions: "write everything in English", BaseBranch: "develop"}}
	trusted := &RepoConfig{PR: PRRaw{Instructions: "Title: English, then a Chinese clause. Body: Chinese first, English folded below."}}

	effective := EffectiveRepoConfig(pushed, trusted, false)
	if effective.PR.Instructions != trusted.PR.Instructions {
		t.Fatalf("PR.Instructions = %q, want the trusted content policy", effective.PR.Instructions)
	}

	// The commands opt-in is about code execution the maintainer authorized;
	// it must not silently hand the pushed branch the drafting policy either.
	effective = EffectiveRepoConfig(pushed, trusted, true)
	if effective.PR.Instructions != trusted.PR.Instructions {
		t.Fatalf("PR.Instructions = %q under allow_repo_commands, want the trusted content policy", effective.PR.Instructions)
	}

	// Without a trusted copy the pushed policy is discarded entirely rather
	// than falling back to the branch, with and without the commands opt-in.
	for _, allowRepoCommands := range []bool{false, true} {
		effective = EffectiveRepoConfig(pushed, nil, allowRepoCommands)
		if effective.PR.Instructions != "" {
			t.Fatalf("without a trusted copy the pushed content policy must be dropped (allow_repo_commands=%v), got %q", allowRepoCommands, effective.PR.Instructions)
		}
	}

	// allow_repo_commands keeps the pre-existing pushed-base-branch behavior:
	// only instructions is trusted-only regardless of the opt-in.
	effective = EffectiveRepoConfig(pushed, trusted, true)
	if effective.PR.BaseBranch != "develop" {
		t.Fatalf("PR.BaseBranch = %q under allow_repo_commands, want the pushed branch", effective.PR.BaseBranch)
	}

	if pushed.PR.Instructions != "write everything in English" {
		t.Fatal("pushed config was mutated")
	}
}

func TestLoadRepo_PRInstructions(t *testing.T) {
	cfg, err := LoadRepoFromBytes([]byte("pr:\n  instructions: |\n    Body: Chinese first, English folded below.\n"))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if !strings.Contains(cfg.PR.Instructions, "Body: Chinese first, English folded below.") {
		t.Fatalf("PR.Instructions = %q", cfg.PR.Instructions)
	}
}

// A repository that says nothing about PR content keeps the built-in drafting
// behavior, and a config without a pr section must still parse.
func TestLoadRepo_WithoutPRSectionStillParses(t *testing.T) {
	cfg, err := LoadRepoFromBytes([]byte("commands:\n  lint: \"make lint\"\n"))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if cfg.PR.Instructions != "" || cfg.PR.BaseBranch != "" {
		t.Fatalf("PR = %+v, want the zero value", cfg.PR)
	}
}

func TestMerge_ResolvesPRInstructions(t *testing.T) {
	repo := &RepoConfig{PR: PRRaw{Instructions: "  body in Chinese  "}}
	got := Merge(&GlobalConfig{}, repo)
	if got.PR.Instructions != "body in Chinese" {
		t.Fatalf("PR.Instructions = %q, want trimmed", got.PR.Instructions)
	}
}
