# Changelog

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
