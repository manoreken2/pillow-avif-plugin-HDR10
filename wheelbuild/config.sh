# Used by multibuild for building wheels
set -eo pipefail

CONFIG_DIR=$(abspath $(dirname "${BASH_SOURCE[0]}"))

ARCHIVE_SDIR=pillow-avif-plugin-depends
LIBAVIF_VERSION=0.11.0
CARGO_C_VERSION=0.9.13
AOM_VERSION=3.5.0
DAV1D_VERSION=1.0.0
SVT_AV1_VERSION=1.3.0
RAV1E_VERSION=0.5.1
LIBWEBP_SHA=15a91ab179b0b605727d16fb751c12674da9dfec
LIBYUV_SHA=f9fda6e7
CCACHE_VERSION=4.7.1
SCCACHE_VERSION=0.3.0
export PERLBREWURL=https://raw.githubusercontent.com/gugod/App-perlbrew/release-0.92/perlbrew
export GITHUB_ACTIONS=1

if [[ "$MB_ML_VER" == "1" ]]; then
    RAV1E_VERSION=0.4.1
    CARGO_C_VERSION=0.7.2
fi

# Convenience functions to run shell commands suppressed from "set -x" tracing
shopt -s expand_aliases
alias trace_on='{ set -x; } 2>/dev/null'
alias trace_off='{ set +x; } 2>/dev/null'
alias trace_suppress='{ [[ $- =~ .*x.* ]] && trace_enabled=1 || trace_enabled=0; set +x; } 2>/dev/null'
alias trace_restore='{ [ $trace_enabled -eq 1 ] && trace_on || trace_off; } 2>/dev/null'

call_and_restore_trace() {
    local rc
    local force_trace
    if [[ "$1" == "-x" ]]; then
      force_trace=1
      shift
    fi
    "$@"
    rc=$?
    [ -n "$force_trace" ] && trace_on || trace_restore
    { return $rc; } 2>/dev/null
}
alias echo='trace_suppress; call_and_restore_trace builtin echo'

function echo_if_gha() {
  [ -n "$GITHUB_ACTIONS" ] && builtin echo "$@" || true
}

GHA_ACTIVE_GROUP=""
function __group_start_ {
  local was_active_group="$GHA_ACTIVE_GROUP"
  [ -n "$GHA_ACTIVE_GROUP" ] && echo_if_gha "::endgroup::" ||:
  GHA_ACTIVE_GROUP="1"
  echo_if_gha -n "::group::"
}

alias group_start='trace_suppress; __group_start_; call_and_restore_trace -x echo_if_gha'

function __group_end_ {
  ACTIVE_GROUP=""
  echo_if_gha "::endgroup::"
  trace_off
}

alias group_end='trace_suppress; __group_end_'


# If we're running in GitHub Actions, then send redirect stderr to
# stdout to ensure that they are interleaved correctly
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  exec 2>&1
fi

function install_ccache {
    mkdir -p $PWD/ccache
    if [ -e /parent-home ]; then
        ln -s $PWD/ccache /parent-home/.ccache
    fi
    ln -s $PWD/ccache $HOME/.ccache

    group_start "Install ccache"
    if [ -n "$IS_MACOS" ]; then
        brew install ccache
        export CCACHE_CPP2=1
    elif [[ "$PLAT" == "x86_64" ]] && [[ $MB_ML_VER == "2014" ]]; then
        local base_url="https://github.com/ccache/ccache/releases/download/v$CCACHE_VERSION"
        local archive_name="ccache-${CCACHE_VERSION}-linux-x86_64"
        fetch_unpack "${base_url}/${archive_name}.tar.xz"
        if [ -e "$archive_name/ccache" ]; then
            cp "$archive_name/ccache" "/usr/local/bin/ccache"
            chmod +x /usr/local/bin/ccache
        fi
    elif [ -n "$IS_ALPINE" ]; then
        suppress apk add ccache
    else
        if [[ $MB_ML_VER == "_2_24" ]]; then
            # debian:9 based distro
            suppress apt-get install -y ccache
        elif [[ $MB_ML_VER == "2014" ]] && [[ "$PLAT" == "i686" ]]; then
            # There is no ccache rpm for el7.i686, but the one from EPEL 6 works fine
            yum install -y https://archives.fedoraproject.org/pub/archive/epel/6/i386/Packages/c/ccache-3.1.6-2.el6.i686.rpm
        else
            # centos based distro
            suppress yum_install epel-release
            suppress yum_install ccache
        fi
    fi
    group_end
}

function install_sccache {
    group_start "Install sccache"
    if [ -n "$IS_MACOS" ]; then
        brew install sccache
    elif [ ! -e /usr/local/bin/sccache ]; then
        local base_url="https://github.com/mozilla/sccache/releases/download/v$SCCACHE_VERSION"
        local archive_name="sccache-v${SCCACHE_VERSION}-${PLAT}-unknown-linux-musl"
        fetch_unpack "${base_url}/${archive_name}.tar.gz"
        if [ -e "$archive_name/sccache" ]; then
            cp "$archive_name/sccache" "/usr/local/bin/sccache"
            chmod +x /usr/local/bin/sccache
        fi
    fi
    if [ -e /usr/local/bin/sccache ]; then
        export USE_SCCACHE=1
        export RUSTC_WRAPPER=/usr/local/bin/sccache
        export SCCACHE_DIR=$PWD/sccache
    fi
    group_end
}

function install_meson {
    if [ -e meson-stamp ]; then return; fi

    install_ninja

    group_start "Install meson"
    if [ -n "$IS_MACOS" ]; then
        brew install meson
    else
        if [ "$MB_PYTHON_VERSION" == "2.7" ]; then
            local python39_exe=$(cpython_path 3.9)/bin/python
            $python39_exe -m pip install meson
            local meson_exe=$(dirname $python39_exe)/meson
            if [ "$(id -u)" != "0" ]; then
                sudo ln -s $meson_exe /usr/local/bin
            else
                ln -s $meson_exe /usr/local/bin
            fi
        else
            $PYTHON_EXE -m pip install meson
        fi
    fi
    group_end

    touch meson-stamp
}

function install_ninja {
    if [ -e ninja-stamp ]; then return; fi

    group_start "Install ninja"

    if [ -n "$IS_MACOS" ]; then
        brew install ninja
    else
        $PYTHON_EXE -m pip install ninja
        local ninja_exe=$(dirname $PYTHON_EXE)/ninja
        ln -s $ninja_exe /usr/local/bin/ninja-build
    fi

    group_end
    touch ninja-stamp
}

function install_rust {
    if [ -e rust-stamp ]; then return; fi

    group_start "Install rust"

    if [[ -n "$IS_ALPINE" ]]; then
        # Increase pthread stack size for musl libc
        export RUSTFLAGS="-C link-args=-Wl,-z,stack-size=2097152 -C target-feature=-crt-static"
    fi

    if [ -n "$IS_MACOS" ]; then
        if [ "$PLAT" == "arm64" ]; then
            brew install rustup-init
            rustup-init -y --target aarch64-apple-darwin
        else
            brew install rust
        fi
    else
        if [[ "$MB_ML_VER" == "1" ]]; then
            # Download and use old rustup-init that's compatible with glibc on el5
            curl -sLO https://static.rust-lang.org/rustup/archive/1.22.1/$PLAT-unknown-linux-gnu/rustup-init
            chmod u+x rustup-init
            ./rustup-init --default-toolchain nightly-2020-07-18 -y
        elif [[ "$MB_ML_VER" == "2010" ]]; then
            curl -sLO https://static.rust-lang.org/rustup/archive/1.25.1/$PLAT-unknown-linux-gnu/rustup-init
            chmod u+x rustup-init
            ./rustup-init --default-toolchain 1.63.0 -y
        else
            curl https://sh.rustup.rs -sSf | /bin/sh -s -- -y
        fi
    fi
    if [ -e $HOME/.cargo/env ]; then
        source $HOME/.cargo/env
    fi

    group_end

    touch rust-stamp
}

function install_cargo_c {
    install_rust

    if which cargo-cbuild 1>/dev/null 2>/dev/null; then return; fi

    group_start "Install cargo-c"

    if [ -n "$IS_MACOS" ]; then
        brew install cargo-c
    else
        mkdir -p $HOME/.cargo/bin
        local archive_fname
        if [ "$PLAT" == "arm64" ]; then
            archive_fname=cargo-c-linux-aarch64.tar.gz
        elif [ "$PLAT" == "i686" ]; then
            archive_fname=cargo-c-linux-i686.tar.gz
        else
            archive_fname=cargo-c-linux.tar.gz
        fi
        fetch_unpack \
            https://github.com/fdintino/cargo-c/releases/download/v$CARGO_C_VERSION/$archive_fname  \
            cargo-c-$CARGO_C_VERSION-linux.tar.gz
        mv cargo-c{api,build,install} $HOME/.cargo/bin
    fi

    group_end
}

function build_aom {
    if [ -e aom-stamp ]; then return; fi

    group_start "Build aom"

    local cmake_flags=()

    if [ -n "$IS_MACOS" ]; then
        brew remove --ignore-dependencies aom php imagemagick libavif libheif gd composer
    fi

    fetch_unpack \
        https://storage.googleapis.com/aom-releases/libaom-$AOM_VERSION.tar.gz

    if [ ! -n "$IS_MACOS" ] && [[ "$MB_ML_VER" == "1" ]]; then
        (cd libaom-$AOM_VERSION \
            && patch -p1 -i $CONFIG_DIR/aom-2.0.2-manylinux1.patch)
    fi
    if [ ! -n "$IS_MACOS" ]; then
        cmake_flags+=("-DCMAKE_C_FLAGS=-fPIC")
    elif [ "$PLAT" == "arm64" ]; then
        cmake_flags+=(\
            -DAOM_TARGET_CPU=arm64 \
            -DCONFIG_RUNTIME_CPU_DETECT=0 \
            -DCMAKE_SYSTEM_PROCESSOR=arm64 \
            -DCMAKE_OSX_ARCHITECTURES=arm64)
    fi
    if [[ $(type -P ccache) ]]; then
        cmake_flags+=(\
            -DCMAKE_C_COMPILER_LAUNCHER=$(type -P ccache) \
            -DCMAKE_CXX_COMPILER_LAUNCHER=$(type -P ccache))
    fi
    if [ -n "$IS_ALPINE" ]; then
        (cd libaom-$AOM_VERSION \
            && patch -p1 -i $CONFIG_DIR/aom-fix-stack-size.patch)
        extra_cmake_flags+=("-DCMAKE_EXE_LINKER_FLAGS=-Wl,-z,stack-size=2097152")
    fi

    # Fix for https://github.com/AOMediaCodec/libavif/issues/1190
    (cd libaom-$AOM_VERSION \
        && patch -p1 -i $CONFIG_DIR/aom-3.5.0-monochrome-realtime-encode.patch)

    mkdir libaom-$AOM_VERSION/build/work
    (cd libaom-$AOM_VERSION/build/work \
        && cmake \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="${BUILD_PREFIX}" \
            -DCMAKE_INSTALL_LIBDIR=lib \
            -DBUILD_SHARED_LIBS=0 \
            -DENABLE_DOCS=0 \
            -DENABLE_EXAMPLES=0 \
            -DENABLE_TESTDATA=0 \
            -DENABLE_TESTS=0 \
            -DENABLE_TOOLS=0 \
            "${cmake_flags[@]}" \
            ../.. \
        && make install)
    group_end
    touch aom-stamp
}

function build_dav1d {
    if [ -e dav1d-stamp ]; then return; fi

    local cflags="$CFLAGS"
    local ldflags="$LDFLAGS"
    local meson_flags=()

    local CC=$(type -P "${CC:-gcc}")
    local CXX=$(type -P "${CXX:-g++}")
    if [[ $(type -P ccache) ]]; then
        CC="$(type -P ccache) $CC"
        CXX="$(type -P ccache) $CXX"
    fi

    group_start "Build dav1d"
    fetch_unpack "https://code.videolan.org/videolan/dav1d/-/archive/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.gz"

    cat <<EOF > dav1d-$DAV1D_VERSION/config.txt
[binaries]
c     = 'clang'
cpp   = 'clang++'
ar    = 'ar'
ld    = 'ld'
strip = 'strip'
[built-in options]
c_args = '$CFLAGS'
c_link_args = '$LDFLAGS'
[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm'
endian = 'little'
EOF

    if [ "$PLAT" == "arm64" ]; then
        cflags=""
        ldflags=""
        meson_flags+=(--cross-file config.txt)
    fi

    (cd dav1d-$DAV1D_VERSION \
        && CFLAGS="$cflags" LDFLAGS="$ldflags" CC="$CC" CXX="$CXX" \
           meson . build \
              "--prefix=${BUILD_PREFIX}" \
              --default-library=static \
              --buildtype=release \
              -D enable_tools=false \
              -D enable_tests=false \
             "${meson_flags[@]}" \
        && SCCACHE_DIR="$SCCACHE_DIR" ninja -vC build install)
    group_end
    touch dav1d-stamp
}

function build_svt_av1 {
    if [ -e svt-av1-stamp ]; then return; fi

    group_start "Build SVT-AV1"

    fetch_unpack \
        "https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v$SVT_AV1_VERSION/SVT-AV1-v$SVT_AV1_VERSION.tar.gz"

    local extra_cmake_flags=()
    if [ -n "$IS_ALPINE" ]; then
        extra_cmake_flags+=("-DCMAKE_EXE_LINKER_FLAGS=-Wl,-z,stack-size=2097152")
    fi
    if [[ $(type -P ccache) ]]; then
        extra_cmake_flags+=(\
            -DCMAKE_C_COMPILER_LAUNCHER=$(type -P ccache) \
            -DCMAKE_CXX_COMPILER_LAUNCHER=$(type -P ccache))
    fi
    (cd SVT-AV1-v$SVT_AV1_VERSION/Build/linux \
        && cmake \
            ../.. \
            -DCMAKE_INSTALL_PREFIX="${BUILD_PREFIX}" \
            -DBUILD_SHARED_LIBS=OFF \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_LIBDIR=lib \
            "${extra_cmake_flags[@]}" \
        && make install \
        && cp SvtAv1Enc.pc $BUILD_PREFIX/lib/pkgconfig)

    group_end

    touch svt-av1-stamp
}

function build_rav1e {
    install_cargo_c

    group_start "Build rav1e"

    RAV1E_CARGO_VENDOR_TGZ=$ARCHIVE_SDIR/rav1e-vendor-$RAV1E_VERSION.tar.gz
    if [ -e $RAV1E_CARGO_VENDOR_TGZ ]; then
        mkdir -p "$HOME/.cargo"
        VENDOR_DIR=$(pwd -P)/$ARCHIVE_SDIR/vendor
        rm -rf $VENDOR_DIR
        tar -C $ARCHIVE_SDIR -zxf $RAV1E_CARGO_VENDOR_TGZ
        cat > ~/.cargo/config <<EOF
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "$VENDOR_DIR"
EOF
    fi

    fetch_unpack \
        "https://github.com/xiph/rav1e/archive/v$RAV1E_VERSION.tar.gz" \
        "rav1e-$RAV1E_VERSION.tar.gz"

    # Strip rust version check
    perl -p0i -e 's/(?<=fn rustc_version_check\(\) {).*?(?=\n}\n)//ms' \
        rav1e-$RAV1E_VERSION/build.rs

    local cargo_c_flags=()
    if [ -n "$IS_MACOS" ] && [ "$PLAT" == "arm64" ]; then
        cargo_c_flags+=(--target=aarch64-apple-darwin)
    fi

    (cd rav1e-$RAV1E_VERSION \
        && cargo cinstall \
            --release \
            --library-type=staticlib \
            "--prefix=$BUILD_PREFIX" \
            "${cargo_c_flags[@]}")

    if [ ! -n "$IS_MACOS" ]; then
        sed -i 's/-lgcc_s/-lgcc_eh/g' "${BUILD_PREFIX}/lib/pkgconfig/rav1e.pc"
    fi

    group_end
}

function build_libsharpyuv {
    if [ -e libsharpyuv-stamp ]; then return; fi

    group_start "Build libsharpyuv"
    fetch_unpack https://github.com/webmproject/libwebp/archive/$LIBWEBP_SHA.tar.gz libwebp-$LIBWEBP_SHA.tar.gz

    mkdir -p libwebp-$LIBWEBP_SHA/build

    local cmake_flags=()
    if [[ $(type -P ccache) ]]; then
        cmake_flags+=(\
            -DCMAKE_C_COMPILER_LAUNCHER=$(type -P ccache) \
            -DCMAKE_CXX_COMPILER_LAUNCHER=$(type -P ccache))
    fi

    (cd libwebp-$LIBWEBP_SHA/build \
        && cmake .. -G Ninja \
            -DCMAKE_INSTALL_PREFIX=$BUILD_PREFIX \
            -DCMAKE_BUILD_TYPE=Release \
            -DBUILD_SHARED_LIBS=OFF \
             "${cmake_flags[@]}" \
        && ninja sharpyuv)
    group_end
    touch libsharpyuv-stamp
}

function build_libyuv {
    if [ -e libyuv-stamp ]; then return; fi

    group_start "Build libyuv"

    mkdir -p libyuv-$LIBYUV_SHA
    (cd libyuv-$LIBYUV_SHA && \
        fetch_unpack "https://chromium.googlesource.com/libyuv/libyuv/+archive/$LIBYUV_SHA.tar.gz")
    mkdir -p libyuv-$LIBYUV_SHA/build
    local cmake_flags=()
    if [ ! -n "$IS_MACOS" ]; then
        cmake_flags+=("-DCMAKE_POSITION_INDEPENDENT_CODE=ON")
    fi
    if [[ $(type -P ccache) ]]; then
        cmake_flags+=(\
            -DCMAKE_C_COMPILER_LAUNCHER=$(type -P ccache) \
            -DCMAKE_CXX_COMPILER_LAUNCHER=$(type -P ccache))
    fi
    (cd libyuv-$LIBYUV_SHA/build \
        && cmake -G Ninja .. \
            -DBUILD_SHARED_LIBS=0 \
            -DCMAKE_BUILD_TYPE=Release \
            "${cmake_flags[@]}" .. \
        && ninja yuv)
    group_end
    touch libyuv-stamp
}

function build_libavif {
    LIBAVIF_CMAKE_FLAGS=()

    build_aom
    LIBAVIF_CMAKE_FLAGS+=(-DAVIF_CODEC_AOM=ON)

    build_dav1d
    LIBAVIF_CMAKE_FLAGS+=(-DAVIF_CODEC_DAV1D=ON)

    if [ "$PLAT" == "x86_64" ]; then
        if [ -n "$IS_MACOS" ]; then
            build_svt_av1
            LIBAVIF_CMAKE_FLAGS+=(-DAVIF_CODEC_SVT=ON)
        elif [[ "$MB_ML_VER" != "1" ]]; then
            LDFLAGS=-lrt build_svt_av1
            LIBAVIF_CMAKE_FLAGS+=(-DCMAKE_EXE_LINKER_FLAGS=-lrt)
            LIBAVIF_CMAKE_FLAGS+=(-DAVIF_CODEC_SVT=ON)
        fi
    fi

    build_rav1e
    LIBAVIF_CMAKE_FLAGS+=(-DAVIF_CODEC_RAV1E=ON)

    if [ -n "$IS_MACOS" ]; then
        # Prevent cmake from using @rpath in install id, so that delocate can
        # find and bundle the libavif dylib
        LIBAVIF_CMAKE_FLAGS+=(\
            "-DCMAKE_INSTALL_NAME_DIR=$BUILD_PREFIX/lib" \
            -DCMAKE_MACOSX_RPATH=OFF)
        if [ "$PLAT" == "arm64" ]; then
            LIBAVIF_CMAKE_FLAGS+=(\
                -DCMAKE_SYSTEM_PROCESSOR=arm64 \
                -DCMAKE_OSX_ARCHITECTURES=arm64)
        fi
    else
        LIBAVIF_CMAKE_FLAGS+=("-DCMAKE_POSITION_INDEPENDENT_CODE=ON")
    fi
    if [[ $(type -P ccache) ]]; then
        LIBAVIF_CMAKE_FLAGS+=(\
            -DCMAKE_C_COMPILER_LAUNCHER=$(type -P ccache) \
            -DCMAKE_CXX_COMPILER_LAUNCHER=$(type -P ccache))
    fi

    group_start "Download libavif source"

    fetch_unpack \
        "https://github.com/AOMediaCodec/libavif/archive/v$LIBAVIF_VERSION.tar.gz" \
        "libavif-$LIBAVIF_VERSION.tar.gz"

    group_end

    build_libsharpyuv
    mv libwebp-$LIBWEBP_SHA libavif-$LIBAVIF_VERSION/ext/libwebp
    LIBAVIF_CMAKE_FLAGS+=(-DAVIF_LOCAL_LIBSHARPYUV=ON)

    build_libyuv
    mv libyuv-$LIBYUV_SHA libavif-$LIBAVIF_VERSION/ext/libyuv
    LIBAVIF_CMAKE_FLAGS+=(-DAVIF_LOCAL_LIBYUV=ON)

    group_start "Build libavif"

    mkdir -p libavif-$LIBAVIF_VERSION/build

    (cd libavif-$LIBAVIF_VERSION/build \
        && cmake .. \
            -DCMAKE_INSTALL_PREFIX=$BUILD_PREFIX \
            -DCMAKE_BUILD_TYPE=Release \
            "${LIBAVIF_CMAKE_FLAGS[@]}" \
        && make install)

    group_end
}

function build_nasm {
    group_start "Build nasm"
    local CC=$(type -P "${CC:-gcc}")
    local CXX=$(type -P "${CXX:-g++}")
    if [[ $(type -P ccache) ]]; then
        CC="$(type -P ccache) $CC"
        CXX="$(type -P ccache) $CXX"
    fi
    SCCACHE_DIR="$SCCACHE_DIR" CC="$CC" CXX="$CXX" build_simple nasm 2.15.05 https://www.nasm.us/pub/nasm/releasebuilds/2.15.05/
    group_end
}

function install_cmake {
    group_start "Install cmake"
    if [ -n "$IS_MACOS" ]; then
        brew install cmake
    else
        if [[ "$MB_ML_VER" == "1" ]]; then
            $PYTHON_EXE -m pip install 'cmake<3.23'
        else
            $PYTHON_EXE -m pip install cmake
        fi
    fi
    group_end
}

function install_zlib {
    if [ ! -n "$IS_MACOS" ]; then
        group_start "Install zlib"
        build_zlib
        group_end
    fi
}

function build_openssl {
    if [ -e openssl-stamp ]; then return; fi
    group_start "Building openssl"
    if [[ "$MB_ML_VER" == "1" ]]; then
        # Install new Perl because OpenSSL configure scripts require > 5.10.0.
        curl -L http://cpanmin.us | perl - App::cpanminus
        cpanm File::Path
        cpanm parent
        curl -L https://install.perlbrew.pl | bash
        source $HOME/perl5/perlbrew/etc/bashrc
        perlbrew install -j 3 --notest perl-5.16.0
        perlbrew use perl-5.16.0
    fi
    fetch_unpack ${OPENSSL_DOWNLOAD_URL}/${OPENSSL_ROOT}.tar.gz
    check_sha256sum $ARCHIVE_SDIR/${OPENSSL_ROOT}.tar.gz ${OPENSSL_HASH}
    local CC=$(type -P "${CC:-gcc}")
    local CXX=$(type -P "${CXX:-g++}")
    if [[ $(type -P ccache) ]]; then
        CC="$(type -P ccache) $CC"
        CXX="$(type -P ccache) $CXX"
    fi
    (cd ${OPENSSL_ROOT} \
        && CC="$CC" CXX="$CXX" ./config no-ssl2 no-shared no-tests -fPIC --prefix=$BUILD_PREFIX \
        && SCCACHE_DIR="$SCCACHE_DIR" make -j4 \
        && make install_sw)
    touch openssl-stamp
    group_end
}

function ensure_openssl {
    if [ ! -n "$IS_MACOS" ]; then
        group_start "Install openssl"
        if [ -n "$IS_ALPINE" ]; then
            apk add libressl-dev openssl-dev
        elif [[ $MB_ML_VER == "_2_24" ]]; then
            apt-get install -y libssl-dev
        else
            yum_install openssl-devel
        fi
        group_end
    fi
}

function ensure_sudo {
    if [ ! -e /usr/bin/sudo ]; then
        group_start "Install sudo"
        if [ -n "$IS_ALPINE" ]; then
            apk add sudo
        elif [[ $MB_ML_VER == "_2_24" ]]; then
            apt-get install -y sudo
        else
            yum_install sudo
        fi
        group_end
    fi
}

function append_licenses {
    group_start "Append licenses"
    for filename in $REPO_DIR/wheelbuild/dependency_licenses/*.txt; do
      echo -e "\n\n----\n\n$(basename $filename | cut -f 1 -d '.')\n" | cat >> $REPO_DIR/LICENSE
      cat $filename >> $REPO_DIR/LICENSE
    done
    echo -e "\n\n" | cat >> $REPO_DIR/LICENSE
    cat $REPO_DIR/wheelbuild/dependency_licenses/PATENTS >> $REPO_DIR/LICENSE
    group_end
}

function pre_build {
    echo "::endgroup::"

    append_licenses
    ensure_sudo
    ensure_openssl
    install_zlib
    install_sccache
    install_ccache

    if [ "$PLAT" != "arm64" ]; then
        build_nasm
    fi
    install_cmake
    install_ninja
    install_meson
    install_rust

    if [ -e $HOME/.cargo/env ]; then
        source $HOME/.cargo/env
    fi

    build_libavif

    echo "::group::Build wheel"
}

function run_tests {
    if ! $PYTHON_EXE -m unittest.mock 2>&1 2>/dev/null; then
        $PYTHON_EXE -m pip install mock
    fi
    # Runs tests on installed distribution from an empty directory
    (cd ../pillow-avif-plugin && pytest)
}

# Work around flakiness of pip install with python 2.7
if [ "$MB_PYTHON_VERSION" == "2.7" ]; then
    function pip_install {
        if [ "$1" == "retry" ]; then
            shift
            echo ""
            echo Retrying pip install $@
        else
            echo Running pip install $@
        fi
        echo ""
        $PIP_CMD install $(pip_opts) $@
    }

    function install_run {
        if [ -n "$TEST_DEPENDS" ]; then
            while read TEST_DEPENDENCY; do
                pip_install $TEST_DEPENDENCY \
                    || pip_install retry $TEST_DEPENDENCY \
                    || pip_install retry $TEST_DEPENDENCY \
                    || pip_install retry $TEST_DEPENDENCY
            done <<< "$TEST_DEPENDS"
            TEST_DEPENDS=""
        fi

        install_wheel
        mkdir tmp_for_test
        (cd tmp_for_test && run_tests)
        rmdir tmp_for_test  2>/dev/null || echo "Cannot remove tmp_for_test"
    }
fi
