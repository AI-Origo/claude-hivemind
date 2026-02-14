# Changelog

## [1.3.0](https://github.com/AI-Origo/claude-hivemind/compare/v1.2.2...v1.3.0) (2026-02-14)


### Features

* enforce task tracking and improve session lifecycle ([fe2fc17](https://github.com/AI-Origo/claude-hivemind/commit/fe2fc17376ca83b4c031491b517ac7b69dc31c1e))
* extend create_task to accept assignee and initial state ([a460d88](https://github.com/AI-Origo/claude-hivemind/commit/a460d88b8d56947044219bf293fe3287f6f8a237))


### Bug Fixes

* filter dashboard tasks to only active states ([a797d62](https://github.com/AI-Origo/claude-hivemind/commit/a797d621db59f7b03481c7404f3efaa2f498320f))


### Refactoring

* simplify wake mechanism and add status line file caching ([d3c02e4](https://github.com/AI-Origo/claude-hivemind/commit/d3c02e40f07f076b4cd190905885d59480272a29))


### Documentation

* simplify README to reflect streamlined feature set ([1b510b8](https://github.com/AI-Origo/claude-hivemind/commit/1b510b8b1ec38c91fdb67388dfb04c69f3a02bb9))


## [1.2.2](https://github.com/AI-Origo/claude-hivemind/compare/v1.2.1...v1.2.2) (2026-02-14)


### Features

* show elapsed time when clearing hive_task ([8f6f157](https://github.com/AI-Origo/claude-hivemind/commit/8f6f157ed5c50fe18c9b038ace2d129865bcabf2))


## [1.2.1](https://github.com/AI-Origo/claude-hivemind/compare/v1.2.0...v1.2.1) (2026-01-29)


### Bug Fixes

* add retry logic for Milvus rate limiting ([4c33bd8](https://github.com/AI-Origo/claude-hivemind/commit/4c33bd8e9cb2116f6d3b6d1c9240ddc4d40580d2))


## [1.2.0](https://github.com/AI-Origo/claude-hivemind/compare/v1.1.3...v1.2.0) (2026-01-29)


### Features

* enforce task reporting after plan acceptance ([507ead7](https://github.com/AI-Origo/claude-hivemind/commit/507ead747eadf0655a70f0db0a7e46bef1972fd5))


## [1.1.3](https://github.com/AI-Origo/claude-hivemind/compare/v1.1.2...v1.1.3) (2026-01-29)


### Bug Fixes

* bash 3.x compatibility and agent name reset on empty swarm ([d01644b](https://github.com/AI-Origo/claude-hivemind/commit/d01644bb6654498498ea58d517e2387d7fc23d1c))


## [1.1.2](https://github.com/AI-Origo/claude-hivemind/compare/v1.1.1...v1.1.2) (2026-01-29)


### Bug Fixes

* ensure version.txt is always updated on setup and session start ([f99f1dc](https://github.com/AI-Origo/claude-hivemind/commit/f99f1dcfd9fe9f885b89aaafe4cc6b11cb985650))


## [1.1.1](https://github.com/AI-Origo/claude-hivemind/compare/v1.1.0...v1.1.1) (2026-01-29)


### Bug Fixes

* reduce dashboard flicker and slow refresh rate ([222fe48](https://github.com/AI-Origo/claude-hivemind/commit/222fe48e531d486ac60e545b6730f7826817a603))


## [1.1.0](https://github.com/AI-Origo/claude-hivemind/compare/v1.0.0...v1.1.0) (2026-01-29)


### Features

* add project-scoped collections and wake queue ([6232a5f](https://github.com/AI-Origo/claude-hivemind/commit/6232a5f74f1d3228feae4a9f0c39f71fbf345a97))


## [1.0.0](https://github.com/AI-Origo/claude-hivemind/compare/v0.15.0...v1.0.0) (2026-01-28)

Milvus is now the required database backend. All data is stored in Milvus collections with project-scoped naming.


## [0.15.0](https://github.com/AI-Origo/claude-hivemind/compare/v0.14.0...v0.15.0) (2026-01-28)


### Features

* add Milvus infrastructure ([dec77e2](https://github.com/AI-Origo/claude-hivemind/commit/dec77e22f52f588b10f829561143cb83c8cd1478))


### Refactoring

* migrate database layer from DuckDB to Milvus ([73b446d](https://github.com/AI-Origo/claude-hivemind/commit/73b446d89ef5040dbd6eafa6d79c04d5a5a9d117))
* update MCP server and handlers for Milvus ([df6bf74](https://github.com/AI-Origo/claude-hivemind/commit/df6bf7480e12b737ca173d55bff107060ed079e9))


### Documentation

* update documentation for Milvus migration ([eed41d2](https://github.com/AI-Origo/claude-hivemind/commit/eed41d23f3379a0a2d8685e1cf1fd6528b6e8f3f))


## [0.14.0](https://github.com/AI-Origo/claude-hivemind/compare/v0.13.2...v0.14.0) (2026-01-27)


### Features

* add DuckDB storage layer and migration utilities ([b5ee075](https://github.com/AI-Origo/claude-hivemind/commit/b5ee075ecc021cd4c19f4517e0a40be274741045))
* add terminal dashboard for agent observability ([de38304](https://github.com/AI-Origo/claude-hivemind/commit/de38304f7a745832e1db2157bc12705ac1612136))


### Refactoring

* migrate hook handlers to DuckDB storage ([bfa7ccb](https://github.com/AI-Origo/claude-hivemind/commit/bfa7ccb8e77d04e41cbe8acdca982a52f52581c7))
* migrate MCP server to DuckDB storage ([ecea50d](https://github.com/AI-Origo/claude-hivemind/commit/ecea50d1b86b9442d70c22ebdea726efd1488901))


### Documentation

* update documentation for DuckDB migration ([94ded2d](https://github.com/AI-Origo/claude-hivemind/commit/94ded2d9dfaf681797e30e6f6ae8761589231b7c))


## [0.13.2](https://github.com/AI-Origo/claude-hivemind/compare/v0.13.1...v0.13.2) (2026-01-26)


### Bug Fixes

* search parent directories for .hivemind in hook handlers ([0535c79](https://github.com/AI-Origo/claude-hivemind/commit/0535c794488794688e7340f6d4575b93e5e2e852))
* use HIVEMIND_DIRNAME env var for MCP server subdirectory support ([2c4606e](https://github.com/AI-Origo/claude-hivemind/commit/2c4606e97be539db7a20fd860be70c09d9071c48))


### Documentation

* add development setup and versioning guide ([a6094de](https://github.com/AI-Origo/claude-hivemind/commit/a6094de7211debdca89d3322ab77073fd3fd21cb))


## [0.13.1](https://github.com/AI-Origo/claude-hivemind/compare/v0.13.0...v0.13.1) (2026-01-25)


### Bug Fixes

* analyze only commits being pushed in pre-push hook ([e8533c2](https://github.com/AI-Origo/claude-hivemind/commit/e8533c230fc81161914d5fb424fb0d4a281d1a07))


## [0.13.0](https://github.com/AI-Origo/claude-hivemind/compare/v0.11.0...v0.13.0) (2026-01-25)


### Features

* replace release-please with local pre-push hook ([97e57cc](https://github.com/AI-Origo/claude-hivemind/commit/97e57cca57caa152fbcb51d83766f01746157bb5))


## [0.11.0](https://github.com/AI-Origo/claude-hivemind/compare/claude-hivemind-v0.10.0...v0.11.0) (2026-01-25)


### Features

* write version file and update startedAt on session recovery ([010c34b](https://github.com/AI-Origo/claude-hivemind/commit/010c34baa77040bc6211de495f5d0eb228b0da9c))


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
