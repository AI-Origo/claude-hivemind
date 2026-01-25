# Changelog

## [0.11.0](https://github.com/AI-Origo/claude-hivemind/compare/claude-hivemind-v0.10.0...claude-hivemind-v0.11.0) (2026-01-25)


### Features

* add /hive install command for status line configuration ([b0f3085](https://github.com/AI-Origo/claude-hivemind/commit/b0f308560294a96e663a72fde88834696b840bdb))
* add agent wake-up feature (macOS + iTerm2) ([286d5c6](https://github.com/AI-Origo/claude-hivemind/commit/286d5c6bf18a0bdc2f85bb83cb881e75a8811681))
* add TTY-based agent identity for stable identification ([52f24c3](https://github.com/AI-Origo/claude-hivemind/commit/52f24c3754a1185cc90a5f65535b2fbb29a7af4e))
* add wake verification instruction for task delegation ([a1f78da](https://github.com/AI-Origo/claude-hivemind/commit/a1f78daa179ce40f38a0aeac89dcaa0fdc80ed73))
* auto-clear task when Claude finishes responding ([bc01796](https://github.com/AI-Origo/claude-hivemind/commit/bc01796c58b2b30213945b246ac30740e8be16b8))
* clean up agent inbox and hivemind directory on exit ([c05405a](https://github.com/AI-Origo/claude-hivemind/commit/c05405a553677143a02b004307b43af5900367ad))
* emphasize early delegation for parallel work ([545e326](https://github.com/AI-Origo/claude-hivemind/commit/545e326ff221ed163b10dff2d5cd4e3c5ef6bb52))
* initial hivemind plugin for multi-agent coordination ([dcedfa5](https://github.com/AI-Origo/claude-hivemind/commit/dcedfa559261ca68bec2439226b4df36f4c5729d))
* show cleared tasks in gray on status line ([1d9ba49](https://github.com/AI-Origo/claude-hivemind/commit/1d9ba49c128ecc68cb4d58abb7b4562a457e6114))
* show hivemind version in statusline when no task is set ([f3d760b](https://github.com/AI-Origo/claude-hivemind/commit/f3d760b4054869e0d50eee47a47e41b46f6966a6))
* write version file and update startedAt on session recovery ([010c34b](https://github.com/AI-Origo/claude-hivemind/commit/010c34baa77040bc6211de495f5d0eb228b0da9c))


### Bug Fixes

* add retry loop and focus verification for agent wake-up ([5459091](https://github.com/AI-Origo/claude-hivemind/commit/5459091f122b5e351f95c66e45b7d9a93d62c186))
* preserve agent identity across session changes ([81ab0d9](https://github.com/AI-Origo/claude-hivemind/commit/81ab0d94115df98b6aba6e292c9ebeba6bf9bc27))
* preserve task state when MCP creates agent file ([d8751f7](https://github.com/AI-Origo/claude-hivemind/commit/d8751f70035c3cdbb669923c9c07123b6aa92c06))
* prevent MCP server hang when sending messages ([9b18199](https://github.com/AI-Origo/claude-hivemind/commit/9b181993f150ad071bb69b90c593aa4a3d7d59bc))
* reclaim agent on TTY match regardless of sessionId state ([db02e0a](https://github.com/AI-Origo/claude-hivemind/commit/db02e0a90aa43fcd4722fbc09bd98a467a2b7b97))
* remove unused broadcast directory ([803bdf4](https://github.com/AI-Origo/claude-hivemind/commit/803bdf4ead74edb6c40c35d569703343a4c2854a))
* verify correct iTerm session by TTY before sending keystrokes ([3908d5d](https://github.com/AI-Origo/claude-hivemind/commit/3908d5dca223d38b879000f18d56d31093970797))


### Refactoring

* improve message handling and add task tracking reminder ([a1336cb](https://github.com/AI-Origo/claude-hivemind/commit/a1336cba8164793c97ead675f7eb78d81d1eac2d))


### Documentation

* document agent wake-up feature and session cleanup ([23d350a](https://github.com/AI-Origo/claude-hivemind/commit/23d350acd537929503b2f24759c19b9e0345ad9d))
* rewrite README as comprehensive developer guide ([12bb97c](https://github.com/AI-Origo/claude-hivemind/commit/12bb97cce1e226b4d63bbbfd3b809133b98b1ef4))
* update README for TTY-based agent identity ([64870ef](https://github.com/AI-Origo/claude-hivemind/commit/64870ef6b81bf3afe0463b0f63e877f8841ea3bc))

## [0.10.0](https://github.com/AI-Origo/claude-hivemind/compare/claude-hivemind-v0.9.0...claude-hivemind-v0.10.0) (2026-01-25)


### Features

* add /hive install command for status line configuration ([b0f3085](https://github.com/AI-Origo/claude-hivemind/commit/b0f308560294a96e663a72fde88834696b840bdb))
* add agent wake-up feature (macOS + iTerm2) ([286d5c6](https://github.com/AI-Origo/claude-hivemind/commit/286d5c6bf18a0bdc2f85bb83cb881e75a8811681))
* add TTY-based agent identity for stable identification ([52f24c3](https://github.com/AI-Origo/claude-hivemind/commit/52f24c3754a1185cc90a5f65535b2fbb29a7af4e))
* add wake verification instruction for task delegation ([a1f78da](https://github.com/AI-Origo/claude-hivemind/commit/a1f78daa179ce40f38a0aeac89dcaa0fdc80ed73))
* auto-clear task when Claude finishes responding ([bc01796](https://github.com/AI-Origo/claude-hivemind/commit/bc01796c58b2b30213945b246ac30740e8be16b8))
* clean up agent inbox and hivemind directory on exit ([c05405a](https://github.com/AI-Origo/claude-hivemind/commit/c05405a553677143a02b004307b43af5900367ad))
* emphasize early delegation for parallel work ([545e326](https://github.com/AI-Origo/claude-hivemind/commit/545e326ff221ed163b10dff2d5cd4e3c5ef6bb52))
* initial hivemind plugin for multi-agent coordination ([dcedfa5](https://github.com/AI-Origo/claude-hivemind/commit/dcedfa559261ca68bec2439226b4df36f4c5729d))
* show cleared tasks in gray on status line ([1d9ba49](https://github.com/AI-Origo/claude-hivemind/commit/1d9ba49c128ecc68cb4d58abb7b4562a457e6114))
* show hivemind version in statusline when no task is set ([f3d760b](https://github.com/AI-Origo/claude-hivemind/commit/f3d760b4054869e0d50eee47a47e41b46f6966a6))


### Bug Fixes

* add retry loop and focus verification for agent wake-up ([5459091](https://github.com/AI-Origo/claude-hivemind/commit/5459091f122b5e351f95c66e45b7d9a93d62c186))
* preserve agent identity across session changes ([81ab0d9](https://github.com/AI-Origo/claude-hivemind/commit/81ab0d94115df98b6aba6e292c9ebeba6bf9bc27))
* preserve task state when MCP creates agent file ([d8751f7](https://github.com/AI-Origo/claude-hivemind/commit/d8751f70035c3cdbb669923c9c07123b6aa92c06))
* prevent MCP server hang when sending messages ([9b18199](https://github.com/AI-Origo/claude-hivemind/commit/9b181993f150ad071bb69b90c593aa4a3d7d59bc))
* reclaim agent on TTY match regardless of sessionId state ([db02e0a](https://github.com/AI-Origo/claude-hivemind/commit/db02e0a90aa43fcd4722fbc09bd98a467a2b7b97))
* remove unused broadcast directory ([803bdf4](https://github.com/AI-Origo/claude-hivemind/commit/803bdf4ead74edb6c40c35d569703343a4c2854a))
* verify correct iTerm session by TTY before sending keystrokes ([3908d5d](https://github.com/AI-Origo/claude-hivemind/commit/3908d5dca223d38b879000f18d56d31093970797))


### Refactoring

* improve message handling and add task tracking reminder ([a1336cb](https://github.com/AI-Origo/claude-hivemind/commit/a1336cba8164793c97ead675f7eb78d81d1eac2d))


### Documentation

* document agent wake-up feature and session cleanup ([23d350a](https://github.com/AI-Origo/claude-hivemind/commit/23d350acd537929503b2f24759c19b9e0345ad9d))
* rewrite README as comprehensive developer guide ([12bb97c](https://github.com/AI-Origo/claude-hivemind/commit/12bb97cce1e226b4d63bbbfd3b809133b98b1ef4))
* update README for TTY-based agent identity ([64870ef](https://github.com/AI-Origo/claude-hivemind/commit/64870ef6b81bf3afe0463b0f63e877f8841ea3bc))
