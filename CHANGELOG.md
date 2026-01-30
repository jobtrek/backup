# Changelog

## [0.2.6](https://github.com/jobtrek/backup/compare/v0.2.5...v0.2.6) (2026-01-30)


### Miscellaneous Chores

* **deps:** bump actions/checkout from 6.0.0 to 6.0.1 ([#25](https://github.com/jobtrek/backup/issues/25)) ([6af38f6](https://github.com/jobtrek/backup/commit/6af38f6da563d05e48b575bc23f0cd598ed501c6))
* **deps:** bump actions/checkout from 6.0.1 to 6.0.2 ([#28](https://github.com/jobtrek/backup/issues/28)) ([c1c5d15](https://github.com/jobtrek/backup/commit/c1c5d15ceca482544a56d5a3f80d9833726963bd))
* **deps:** bump alpine from 3.22 to 3.23 in /backup ([#24](https://github.com/jobtrek/backup/issues/24)) ([7fba0b9](https://github.com/jobtrek/backup/commit/7fba0b9fecd0cdbcc344787fb26b95f16dc08f59))
* **deps:** bump docker/metadata-action from 5.9.0 to 5.10.0 ([#26](https://github.com/jobtrek/backup/issues/26)) ([386011d](https://github.com/jobtrek/backup/commit/386011d6c21c87991bd3e64a7f6c13a30239d726))

## [0.2.5](https://github.com/jobtrek/backup/compare/v0.2.4...v0.2.5) (2025-11-25)


### Miscellaneous Chores

* **deps:** bump actions/checkout from 5.0.0 to 6.0.0 ([#22](https://github.com/jobtrek/backup/issues/22)) ([0f922f7](https://github.com/jobtrek/backup/commit/0f922f7003c04ca07c4ee6f184bac8f2329ea1a6))

## [0.2.4](https://github.com/jobtrek/backup/compare/v0.2.3...v0.2.4) (2025-11-13)


### Features

* **restore:** add support for custom s3 endpoint in restore script ([e1b5e49](https://github.com/jobtrek/backup/commit/e1b5e49cde4eb4ae8fcd4f82a06aaea591e92ef8))
* **restore:** enhance volume restoration with helper image and safety checks ([e1b5e49](https://github.com/jobtrek/backup/commit/e1b5e49cde4eb4ae8fcd4f82a06aaea591e92ef8))
* **restore:** improve volume restoration using docker cp --archive ([#20](https://github.com/jobtrek/backup/issues/20)) ([e1b5e49](https://github.com/jobtrek/backup/commit/e1b5e49cde4eb4ae8fcd4f82a06aaea591e92ef8))


### Documentation

* **backup, restore:** clarify AWS_DEFAULT_REGION usage with garage ([e1b5e49](https://github.com/jobtrek/backup/commit/e1b5e49cde4eb4ae8fcd4f82a06aaea591e92ef8))
* **backup:** garage hint ([e1b5e49](https://github.com/jobtrek/backup/commit/e1b5e49cde4eb4ae8fcd4f82a06aaea591e92ef8))
* **restore:** add restart note in restore readme ([e1b5e49](https://github.com/jobtrek/backup/commit/e1b5e49cde4eb4ae8fcd4f82a06aaea591e92ef8))

## [0.2.3](https://github.com/jobtrek/backup/compare/v0.2.2...v0.2.3) (2025-11-13)


### Bug Fixes

* add tzdata to dependencies in backup and restore Dockerfiles ([#18](https://github.com/jobtrek/backup/issues/18)) ([b244e7c](https://github.com/jobtrek/backup/commit/b244e7c4733ff7f7da424ce64467c0a28e429325))

## [0.2.2](https://github.com/jobtrek/backup/compare/v0.2.1...v0.2.2) (2025-11-12)


### Features

* **restore:** enhance s3 connectivity check with error logging ([#16](https://github.com/jobtrek/backup/issues/16)) ([6790934](https://github.com/jobtrek/backup/commit/67909349eabd36f50cbfced9f26c446040f6145b))

## [0.2.1](https://github.com/jobtrek/backup/compare/v0.2.0...v0.2.1) (2025-11-12)


### Bug Fixes

* **restore:** improve archive extraction method in restore script ([75fa895](https://github.com/jobtrek/backup/commit/75fa8953a2a70d5d9a60b22180979c45568925bf))


### Miscellaneous Chores

* remove unnecessary enhance word ([#15](https://github.com/jobtrek/backup/issues/15)) ([85e4530](https://github.com/jobtrek/backup/commit/85e453081beba04d7cff3668cb93050dc005c4f3))


### Refactors

* replace build context with image for backup and restore services ([#13](https://github.com/jobtrek/backup/issues/13)) ([75fa895](https://github.com/jobtrek/backup/commit/75fa8953a2a70d5d9a60b22180979c45568925bf))


### Build System

* no more image build for PRs ([75fa895](https://github.com/jobtrek/backup/commit/75fa8953a2a70d5d9a60b22180979c45568925bf))

## [0.2.0](https://github.com/jobtrek/backup/compare/v0.1.3...v0.2.0) (2025-11-12)


### ⚠ BREAKING CHANGES

* **backup:** db physical backup is now performed like volumes ([#9](https://github.com/jobtrek/backup/issues/9))

### Features

* implement restore container for S3 backup recovery ([#12](https://github.com/jobtrek/backup/issues/12)) ([c1ed7e8](https://github.com/jobtrek/backup/commit/c1ed7e824c58923a72873a17dff38d12438efefc))


### Bug Fixes

* **backup:** update archive naming convention for clarity ([#10](https://github.com/jobtrek/backup/issues/10)) ([210a14a](https://github.com/jobtrek/backup/commit/210a14a8182b374369c09cda87e8180102ca15a9))


### Refactors

* **backup:** db physical backup is now performed like volumes ([#9](https://github.com/jobtrek/backup/issues/9)) ([f13b50f](https://github.com/jobtrek/backup/commit/f13b50f2af3ee1e03bc92abf8f1943e0c8f90ded))


### Build System

* add condition to skip dependabot for docker job ([#7](https://github.com/jobtrek/backup/issues/7)) ([4094982](https://github.com/jobtrek/backup/commit/4094982ac10d899b12ca7b07f3ed4a4547da69c4))

## [0.1.3](https://github.com/jobtrek/backup/compare/v0.1.2...v0.1.3) (2025-11-11)


### Miscellaneous Chores

* **deps:** bump actions/checkout from 4.3.0 to 5.0.0 ([#4](https://github.com/jobtrek/backup/issues/4)) ([a465d60](https://github.com/jobtrek/backup/commit/a465d60aaa750e037a3c8efa7219842bf3662618))


### Build System

* update build to correctly tag images ([#5](https://github.com/jobtrek/backup/issues/5)) ([fabd816](https://github.com/jobtrek/backup/commit/fabd81677fce2b51687e73e198e1c82bc83117e4))

## [0.1.2](https://github.com/jobtrek/backup/compare/v0.1.1...v0.1.2) (2025-11-10)


### Miscellaneous Chores

* add dependabot configuration and build-publish workflow ([#2](https://github.com/jobtrek/backup/issues/2)) ([563e31e](https://github.com/jobtrek/backup/commit/563e31e8c4199e9cbe01367167079fb9ceec0d47))

## [0.1.1](https://github.com/jobtrek/backup/compare/v0.1.0...v0.1.1) (2025-11-10)


### Miscellaneous Chores

* backup container, copy from old repo ([9c0510e](https://github.com/jobtrek/backup/commit/9c0510e96034955492ae5307ba5cba2fba7cb9fc))
* initial release please setup ([9a72280](https://github.com/jobtrek/backup/commit/9a72280c2f54fe4380222ca211ea598d9d687537))


### Documentation

* repo readme ([5d20108](https://github.com/jobtrek/backup/commit/5d2010803cfdc4a3fb86e4c4b0903e9dfa3e90b3))
