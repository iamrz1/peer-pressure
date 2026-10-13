// Package skills embeds the peer-pressure skill so the installer can write it
// without a clone or a network fetch.
package skills

import "embed"

// Name is the skill directory name. It matches the name in SKILL.md.
const Name = "peer-pressure"

// FS holds the skill folder at its root, for example "peer-pressure/SKILL.md".
//
//go:embed all:peer-pressure
var FS embed.FS
