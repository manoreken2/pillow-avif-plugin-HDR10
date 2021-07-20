#!/bin/bash

set -eo pipefail

if [[ "$MB_PYTHON_VERSION" == pypy3* ]]; then
  if [[ "$TRAVIS_OS_NAME" != "macos-latest" ]]; then
    DOCKER_TEST_IMAGE="multibuild/xenial_$PLAT"
  else
    MB_PYTHON_OSX_VER="10.9"
  fi
fi

if [[ "$MB_PYTHON_VERSION" == "2.7" ]]; then
    DOCKER_TEST_IMAGE="fdintino/trusty-multibuild:$PLAT"
    if [[ "$MB_ML_VER" == "2010" ]]; then
        DOCKER_IMAGE="quay.io/pypa/manylinux${MB_ML_VER}_$PLAT:2021-02-06-3d322a5"
    fi
fi

echo "::group::Install a virtualenv"
  source multibuild/common_utils.sh
  source multibuild/travis_steps.sh
  # can't use default 7.3.1 on macOS due to https://foss.heptapod.net/pypy/pypy/-/issues/3229
  LATEST_PP_7p3=7.3.3
  python3 -m pip install virtualenv
  before_install
echo "::endgroup::"

echo "::group::Setup wheel installation"
  clean_code $REPO_DIR $BUILD_COMMIT
  build_wheel $REPO_DIR $PLAT
  ls -l "${GITHUB_WORKSPACE}/${WHEEL_SDIR}/"
echo "::endgroup::"

echo "::group::Test wheel"
  install_run $PLAT
echo "::endgroup::"
