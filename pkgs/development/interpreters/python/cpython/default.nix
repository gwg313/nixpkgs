{ lib
, stdenv
, fetchurl
, fetchpatch
, fetchgit

# build dependencies
, autoconf-archive
, autoreconfHook
, nukeReferences
, pkg-config
, python-setup-hook

# runtime dependencies
, bzip2
, expat
, libffi
, libxcrypt
, mpdecimal
, ncurses
, openssl
, sqlite
, xz
, zlib

# platform-specific dependencies
, bash
, configd
, darwin
, windows

# optional dependencies
, bluezSupport ? false, bluez
, mimetypesSupport ? true, mailcap
, tzdata
, withGdbm ? !stdenv.hostPlatform.isWindows, gdbm
, withReadline ? !stdenv.hostPlatform.isWindows, readline
, x11Support ? false, tcl, tk, tix, libX11, xorgproto

# splicing/cross
, pythonAttr ? "python${sourceVersion.major}${sourceVersion.minor}"
, self
, pkgsBuildBuild
, pkgsBuildHost
, pkgsBuildTarget
, pkgsHostHost
, pkgsTargetTarget

# build customization
, sourceVersion
, hash
, passthruFun
, stripConfig ? false
, stripIdlelib ? false
, stripTests ? false
, stripTkinter ? false
, rebuildBytecode ? true
, stripBytecode ? true
, includeSiteCustomize ? true
, static ? stdenv.hostPlatform.isStatic
, enableFramework ? false
, noldconfigPatch ? ./. + "/${sourceVersion.major}.${sourceVersion.minor}/no-ldconfig.patch"
, enableGIL ? true

# pgo (not reproducible) + -fno-semantic-interposition
# https://docs.python.org/3/using/configure.html#cmdoption-enable-optimizations
, enableOptimizations ? false

# improves performance, but remains reproducible
, enableNoSemanticInterposition ? true

# enabling LTO on 32bit arch causes downstream packages to fail when linking
, enableLTO ? stdenv.isDarwin || (stdenv.is64bit && stdenv.isLinux)

# enable asserts to ensure the build remains reproducible
, reproducibleBuild ? false

# for the Python package set
, packageOverrides ? (self: super: {})

# tests
, testers

} @ inputs:

# Note: this package is used for bootstrapping fetchurl, and thus
# cannot use fetchpatch! All mutable patches (generated by GitHub or
# cgit) that are needed here should be included directly in Nixpkgs as
# files.

assert x11Support -> tcl != null
                  && tk != null
                  && xorgproto != null
                  && libX11 != null;

assert bluezSupport -> bluez != null;

assert lib.assertMsg (enableFramework -> stdenv.isDarwin)
  "Framework builds are only supported on Darwin.";

assert lib.assertMsg (reproducibleBuild -> stripBytecode)
  "Deterministic builds require stripping bytecode.";

assert lib.assertMsg (reproducibleBuild -> (!enableOptimizations))
  "Deterministic builds are not achieved when optimizations are enabled.";

assert lib.assertMsg (reproducibleBuild -> (!rebuildBytecode))
  "Deterministic builds are not achieved when (default unoptimized) bytecode is created.";

let
  inherit (lib)
    concatMapStringsSep
    concatStringsSep
    enableFeature
    getDev
    getLib
    optionals
    optionalString
    replaceStrings
    versionOlder
  ;

  # mixes libc and libxcrypt headers and libs and causes segfaults on importing crypt
  libxcrypt = if stdenv.hostPlatform.isFreeBSD then null else inputs.libxcrypt;

  buildPackages = pkgsBuildHost;
  inherit (passthru) pythonOnBuildForHost;

  tzdataSupport = tzdata != null && passthru.pythonAtLeast "3.9";

  passthru = let
    # When we override the interpreter we also need to override the spliced versions of the interpreter
    inputs' = lib.filterAttrs (n: v: ! lib.isDerivation v && n != "passthruFun") inputs;
    override = attr: let python = attr.override (inputs' // { self = python; }); in python;
  in passthruFun rec {
    inherit self sourceVersion packageOverrides;
    implementation = "cpython";
    libPrefix = "python${pythonVersion}";
    executable = libPrefix;
    pythonVersion = with sourceVersion; "${major}.${minor}";
    sitePackages = "lib/${libPrefix}/site-packages";
    inherit hasDistutilsCxxPatch pythonAttr;
    pythonOnBuildForBuild = override pkgsBuildBuild.${pythonAttr};
    pythonOnBuildForHost = override pkgsBuildHost.${pythonAttr};
    pythonOnBuildForTarget = override pkgsBuildTarget.${pythonAttr};
    pythonOnHostForHost = override pkgsHostHost.${pythonAttr};
    pythonOnTargetForTarget = lib.optionalAttrs (lib.hasAttr pythonAttr pkgsTargetTarget) (override pkgsTargetTarget.${pythonAttr});
  };

  version = with sourceVersion; "${major}.${minor}.${patch}${suffix}";

  nativeBuildInputs = [
    nukeReferences
  ] ++ optionals (!stdenv.isDarwin) [
    autoconf-archive # needed for AX_CHECK_COMPILE_FLAG
    autoreconfHook
    pkg-config
  ] ++ optionals (stdenv.hostPlatform != stdenv.buildPlatform) [
    buildPackages.stdenv.cc
    pythonOnBuildForHost
  ] ++ optionals (stdenv.cc.isClang && (!stdenv.hostPlatform.useAndroidPrebuilt or false) && (enableLTO || enableOptimizations)) [
    stdenv.cc.cc.libllvm.out
  ];

  buildInputs = lib.filter (p: p != null) ([
    bzip2
    expat
    libffi
    libxcrypt
    mpdecimal
    ncurses
    openssl
    sqlite
    xz
    zlib
  ] ++ optionals bluezSupport [
    bluez
  ] ++ optionals enableFramework [
    darwin.apple_sdk.frameworks.Cocoa
  ] ++ optionals stdenv.hostPlatform.isMinGW [
    windows.dlfcn
    windows.mingw_w64_pthreads
  ] ++ optionals stdenv.isDarwin [
    configd
  ] ++ optionals tzdataSupport [
    tzdata
  ] ++ optionals withGdbm [
    gdbm
  ] ++ optionals withReadline [
    readline
  ] ++ optionals x11Support [
    libX11
    tcl
    tk
    xorgproto
  ]);

  hasDistutilsCxxPatch = !(stdenv.cc.isGNU or false);

  pythonOnBuildForHostInterpreter = if stdenv.hostPlatform == stdenv.buildPlatform then
    "$out/bin/python"
  else pythonOnBuildForHost.interpreter;

  src = fetchurl {
    url = with sourceVersion; "https://www.python.org/ftp/python/${major}.${minor}.${patch}/Python-${version}.tar.xz";
    inherit hash;
  };

  # The CPython interpreter contains a _sysconfigdata_<platform specific suffix>
  # module that is imported by the sysconfig and distutils.sysconfig modules.
  # The sysconfigdata module is generated at build time and contains settings
  # required for building Python extension modules, such as include paths and
  # other compiler flags. By default, the sysconfigdata module is loaded from
  # the currently running interpreter (ie. the build platform interpreter), but
  # when cross-compiling we want to load it from the host platform interpreter.
  # This can be done using the _PYTHON_SYSCONFIGDATA_NAME environment variable.
  # The _PYTHON_HOST_PLATFORM variable also needs to be set to get the correct
  # platform suffix on extension modules. The correct values for these variables
  # are not documented, and must be derived from the configure script (see links
  # below).
  sysconfigdataHook = with stdenv.hostPlatform; with passthru; let
    machdep = if isWindows then "win32" else parsed.kernel.name; # win32 is added by Fedora’s patch

    # https://github.com/python/cpython/blob/e488e300f5c01289c10906c2e53a8e43d6de32d8/configure.ac#L428
    # The configure script uses "arm" as the CPU name for all 32-bit ARM
    # variants when cross-compiling, but native builds include the version
    # suffix, so we do the same.
    pythonHostPlatform = let
      cpu = {
        # According to PEP600, Python's name for the Power PC
        # architecture is "ppc", not "powerpc".  Without the Rosetta
        # Stone below, the PEP600 requirement that "${ARCH} matches
        # the return value from distutils.util.get_platform()" fails.
        # https://peps.python.org/pep-0600/
        powerpc = "ppc";
        powerpcle = "ppcle";
        powerpc64 = "ppc64";
        powerpc64le = "ppc64le";
      }.${parsed.cpu.name} or parsed.cpu.name;
    in "${machdep}-${cpu}";

    # https://github.com/python/cpython/blob/e488e300f5c01289c10906c2e53a8e43d6de32d8/configure.ac#L724
    multiarchCpu =
      if isAarch32 then
        if parsed.cpu.significantByte.name == "littleEndian" then "arm" else "armeb"
      else if isx86_32 then "i386"
      else parsed.cpu.name;

    pythonAbiName = let
      # python's build doesn't match the nixpkgs abi in some cases.
      # https://github.com/python/cpython/blob/e488e300f5c01289c10906c2e53a8e43d6de32d8/configure.ac#L724
      nixpkgsPythonAbiMappings = {
        "gnuabielfv2" = "gnu";
        "muslabielfv2" = "musl";
      };
      pythonAbi = nixpkgsPythonAbiMappings.${parsed.abi.name} or parsed.abi.name;
    in
      # Python <3.11 doesn't distinguish musl and glibc and always prefixes with "gnu"
      if versionOlder version "3.11" then
        replaceStrings [ "musl" ] [ "gnu" ] pythonAbi
      else
        pythonAbi;

    multiarch =
      if isDarwin then "darwin"
      else if isFreeBSD then ""
      else if isWindows then ""
      else "${multiarchCpu}-${machdep}-${pythonAbiName}";

    abiFlags = optionalString isPy37 "m";

    # https://github.com/python/cpython/blob/e488e300f5c01289c10906c2e53a8e43d6de32d8/configure.ac#L78
    pythonSysconfigdataName = "_sysconfigdata_${abiFlags}_${machdep}_${multiarch}";
  in ''
    sysconfigdataHook() {
      if [ "$1" = '${placeholder "out"}' ]; then
        export _PYTHON_HOST_PLATFORM='${pythonHostPlatform}'
        export _PYTHON_SYSCONFIGDATA_NAME='${pythonSysconfigdataName}'
      fi
    }

    addEnvHooks "$hostOffset" sysconfigdataHook
  '';

  execSuffix = stdenv.hostPlatform.extensions.executable;
in with passthru; stdenv.mkDerivation (finalAttrs: {
  pname = "python3";
  inherit src version;

  inherit nativeBuildInputs;
  buildInputs = lib.optionals (!stdenv.hostPlatform.isWindows) [
    bash # only required for patchShebangs
  ] ++ buildInputs;

  prePatch = optionalString stdenv.isDarwin ''
    substituteInPlace configure --replace-fail '`/usr/bin/arch`' '"i386"'
  '' + optionalString (pythonOlder "3.9" && stdenv.isDarwin && x11Support) ''
    # Broken on >= 3.9; replaced with ./3.9/darwin-tcl-tk.patch
    substituteInPlace setup.py --replace-fail /Library/Frameworks /no-such-path
  '';

  patches = [
    # Disable the use of ldconfig in ctypes.util.find_library (since
    # ldconfig doesn't work on NixOS), and don't use
    # ctypes.util.find_library during the loading of the uuid module
    # (since it will do a futile invocation of gcc (!) to find
    # libuuid, slowing down program startup a lot).
    noldconfigPatch
  ] ++ optionals (stdenv.hostPlatform != stdenv.buildPlatform && stdenv.isFreeBSD) [
    # Cross compilation only supports a limited number of "known good"
    # configurations. If you're reading this and it's been a long time
    # since this diff, consider submitting this patch upstream!
    ./freebsd-cross.patch
  ] ++ optionals (pythonOlder "3.13") [
    # Make sure that the virtualenv activation scripts are
    # owner-writable, so venvs can be recreated without permission
    # errors.
    ./virtualenv-permissions.patch
  ] ++ optionals (pythonAtLeast "3.13") [
    ./3.13/virtualenv-permissions.patch
  ] ++ optionals mimetypesSupport [
    # Make the mimetypes module refer to the right file
    ./mimetypes.patch
  ] ++ optionals (pythonAtLeast "3.7" && pythonOlder "3.11") [
    # Fix darwin build https://bugs.python.org/issue34027
    ./3.7/darwin-libutil.patch
  ] ++ optionals (pythonAtLeast "3.11") [
    ./3.11/darwin-libutil.patch
  ] ++ optionals (pythonAtLeast "3.9" && pythonOlder "3.11" && stdenv.isDarwin) [
    # Stop checking for TCL/TK in global macOS locations
    ./3.9/darwin-tcl-tk.patch
  ] ++ optionals (hasDistutilsCxxPatch && pythonOlder "3.12") [
    # Fix for http://bugs.python.org/issue1222585
    # Upstream distutils is calling C compiler to compile C++ code, which
    # only works for GCC and Apple Clang. This makes distutils to call C++
    # compiler when needed.
    (
      if pythonAtLeast "3.7" && pythonOlder "3.11" then
        ./3.7/python-3.x-distutils-C++.patch
      else if pythonAtLeast "3.11" then
        ./3.11/python-3.x-distutils-C++.patch
      else
        fetchpatch {
          url = "https://bugs.python.org/file48016/python-3.x-distutils-C++.patch";
          sha256 = "1h18lnpx539h5lfxyk379dxwr8m2raigcjixkf133l4xy3f4bzi2";
        }
    )
  ] ++ optionals (pythonAtLeast "3.7" && pythonOlder "3.12") [
    # LDSHARED now uses $CC instead of gcc. Fixes cross-compilation of extension modules.
    ./3.8/0001-On-all-posix-systems-not-just-Darwin-set-LDSHARED-if.patch
    # Use sysconfigdata to find headers. Fixes cross-compilation of extension modules.
    ./3.7/fix-finding-headers-when-cross-compiling.patch
  ] ++ optionals (pythonOlder "3.12") [
    # https://github.com/python/cpython/issues/90656
    ./loongarch-support.patch
  ] ++ optionals (pythonAtLeast "3.11" && pythonOlder "3.13") [
    # backport fix for https://github.com/python/cpython/issues/95855
    ./platform-triplet-detection.patch
  ] ++ optionals (stdenv.hostPlatform.isMinGW) (let
    # https://src.fedoraproject.org/rpms/mingw-python3
    mingw-patch = fetchgit {
      name = "mingw-python-patches";
      url = "https://src.fedoraproject.org/rpms/mingw-python3.git";
      rev = "45c45833ab9e5480ad0ae00778a05ebf35812ed4"; # for python 3.11.5 at the time of writing.
      sha256 = "sha256-KIyNvO6MlYTrmSy9V/DbzXm5OsIuyT/BEpuo7Umm9DI=";
    };
  in [
    "${mingw-patch}/*.patch"
  ]);

  postPatch = optionalString (!stdenv.hostPlatform.isWindows) ''
    substituteInPlace Lib/subprocess.py \
      --replace-fail "'/bin/sh'" "'${bash}/bin/sh'"
  '' + optionalString mimetypesSupport ''
    substituteInPlace Lib/mimetypes.py \
      --replace-fail "@mime-types@" "${mailcap}"
  '' + optionalString (pythonOlder "3.13" && x11Support && (tix != null)) ''
    substituteInPlace "Lib/tkinter/tix.py" --replace-fail \
      "os.environ.get('TIX_LIBRARY')" \
      "os.environ.get('TIX_LIBRARY') or '${tix}/lib'"
  '';

  env = {
    CPPFLAGS = concatStringsSep " " (map (p: "-I${getDev p}/include") buildInputs);
    LDFLAGS = concatStringsSep " " (map (p: "-L${getLib p}/lib") buildInputs);
    LIBS = "${optionalString (!stdenv.isDarwin) "-lcrypt"}";
    NIX_LDFLAGS = lib.optionalString (stdenv.cc.isGNU && !stdenv.hostPlatform.isStatic) ({
      "glibc" = "-lgcc_s";
      "musl" = "-lgcc_eh";
    }."${stdenv.hostPlatform.libc}" or "");
    # Determinism: We fix the hashes of str, bytes and datetime objects.
    PYTHONHASHSEED=0;
  };

  # https://docs.python.org/3/using/configure.html
  configureFlags = [
    "--without-ensurepip"
    "--with-system-expat"
    "--with-system-libmpdec"
  ] ++ optionals (openssl != null) [
    "--with-openssl=${openssl.dev}"
  ] ++ optionals tzdataSupport [
    "--with-tzpath=${tzdata}/share/zoneinfo"
  ] ++ optionals (execSuffix != "") [
    "--with-suffix=${execSuffix}"
  ] ++ optionals enableLTO [
    "--with-lto"
  ] ++ optionals (!static && !enableFramework) [
    "--enable-shared"
  ] ++ optionals enableFramework [
    "--enable-framework=${placeholder "out"}/Library/Frameworks"
  ] ++ optionals (pythonAtLeast "3.13") [
    (enableFeature enableGIL "gil")
  ] ++ optionals enableOptimizations [
    "--enable-optimizations"
  ] ++ optionals (stdenv.isDarwin && configd == null) [
    # Make conditional on Darwin for now to avoid causing Linux rebuilds.
    "py_cv_module__scproxy=n/a"
  ] ++ optionals (sqlite != null) [
    "--enable-loadable-sqlite-extensions"
  ] ++ optionals (libxcrypt != null) [
    "CFLAGS=-I${libxcrypt}/include"
    "LIBS=-L${libxcrypt}/lib"
  ] ++ optionals (stdenv.hostPlatform != stdenv.buildPlatform) [
    "ac_cv_buggy_getaddrinfo=no"
    # Assume little-endian IEEE 754 floating point when cross compiling
    "ac_cv_little_endian_double=yes"
    "ac_cv_big_endian_double=no"
    "ac_cv_mixed_endian_double=no"
    "ac_cv_x87_double_rounding=yes"
    "ac_cv_tanh_preserves_zero_sign=yes"
    # Generally assume that things are present and work
    "ac_cv_posix_semaphores_enabled=yes"
    "ac_cv_broken_sem_getvalue=no"
    "ac_cv_wchar_t_signed=yes"
    "ac_cv_rshift_extends_sign=yes"
    "ac_cv_broken_nice=no"
    "ac_cv_broken_poll=no"
    "ac_cv_working_tzset=yes"
    "ac_cv_have_long_long_format=yes"
    "ac_cv_have_size_t_format=yes"
    "ac_cv_computed_gotos=yes"
    # Both fail when building for windows, normally configure checks this by itself but on other platforms this is set to yes always.
    "ac_cv_file__dev_ptmx=${if stdenv.hostPlatform.isWindows then "no" else "yes"}"
    "ac_cv_file__dev_ptc=${if stdenv.hostPlatform.isWindows then "no" else "yes"}"
  ] ++ optionals (stdenv.hostPlatform != stdenv.buildPlatform && pythonAtLeast "3.11") [
    "--with-build-python=${pythonOnBuildForHostInterpreter}"
  ] ++ optionals stdenv.hostPlatform.isLinux [
    # Never even try to use lchmod on linux,
    # don't rely on detecting glibc-isms.
    "ac_cv_func_lchmod=no"
  ] ++ optionals static [
    "LDFLAGS=-static"
  ];

  preConfigure = ''
    # Attempt to purify some of the host info collection
    sed -E -i -e 's/uname -r/echo/g' -e 's/uname -n/echo nixpkgs/g' config.guess
    sed -E -i -e 's/uname -r/echo/g' -e 's/uname -n/echo nixpkgs/g' configure
  '' + optionalString (pythonOlder "3.12") ''
    # Improve purity
    for path in /usr /sw /opt /pkg; do
      substituteInPlace ./setup.py --replace-warn $path /no-such-path
    done
  '' + optionalString stdenv.isDarwin ''
    # Override the auto-detection in setup.py, which assumes a universal build
    export PYTHON_DECIMAL_WITH_MACHINE=${if stdenv.isAarch64 then "uint128" else "x64"}
    # Ensure that modern platform features are enabled on Darwin in spite of having no version suffix.
    sed -E -i -e 's|Darwin/\[12\]\[0-9\]\.\*|Darwin/*|' configure
  '' + optionalString (pythonAtLeast "3.11") ''
    # Also override the auto-detection in `configure`.
    substituteInPlace configure \
      --replace-fail 'libmpdec_machine=universal' 'libmpdec_machine=${if stdenv.isAarch64 then "uint128" else "x64"}'
  '' + optionalString (stdenv.isDarwin && x11Support && pythonAtLeast "3.11") ''
    export TCLTK_LIBS="-L${tcl}/lib -L${tk}/lib -l${tcl.libPrefix} -l${tk.libPrefix}"
    export TCLTK_CFLAGS="-I${tcl}/include -I${tk}/include"
  '' + optionalString stdenv.hostPlatform.isMusl ''
    export NIX_CFLAGS_COMPILE+=" -DTHREAD_STACK_SIZE=0x100000"
  '' +

  # enableNoSemanticInterposition essentially sets that CFLAG -fno-semantic-interposition
  # which changes how symbols are looked up. This essentially means we can't override
  # libpython symbols via LD_PRELOAD anymore. This is common enough as every build
  # that uses --enable-optimizations has the same "issue".
  #
  # The Fedora wiki has a good article about their journey towards enabling this flag:
  # https://fedoraproject.org/wiki/Changes/PythonNoSemanticInterpositionSpeedup
  optionalString enableNoSemanticInterposition ''
    export CFLAGS_NODIST="-fno-semantic-interposition"
  '';

  setupHook = python-setup-hook sitePackages;

  postInstall = let
    # References *not* to nuke from (sys)config files
    keep-references = concatMapStringsSep " " (val: "-e ${val}") ([
      (placeholder "out")
    ] ++ lib.optional (libxcrypt != null) libxcrypt
      ++ lib.optional tzdataSupport tzdata
    );
  in lib.optionalString enableFramework ''
    for dir in include lib share; do
      ln -s $out/Library/Frameworks/Python.framework/Versions/Current/$dir $out/$dir
    done
  '' + ''
    # needed for some packages, especially packages that backport functionality
    # to 2.x from 3.x
    for item in $out/lib/${libPrefix}/test/*; do
      if [[ "$item" != */test_support.py*
         && "$item" != */test/support
         && "$item" != */test/libregrtest
         && "$item" != */test/regrtest.py* ]]; then
        rm -rf "$item"
      else
        echo $item
      fi
    done
    touch $out/lib/${libPrefix}/test/__init__.py

    # Determinism: Windows installers were not deterministic.
    # We're also not interested in building Windows installers.
    find "$out" -name 'wininst*.exe' | xargs -r rm -f

    # Use Python3 as default python
    ln -s "$out/bin/idle3" "$out/bin/idle"
    ln -s "$out/bin/pydoc3" "$out/bin/pydoc"
    ln -s "$out/bin/python3${execSuffix}" "$out/bin/python${execSuffix}"
    ln -s "$out/bin/python3-config" "$out/bin/python-config"
    ln -s "$out/lib/pkgconfig/python3.pc" "$out/lib/pkgconfig/python.pc"
    ln -sL "$out/share/man/man1/python3.1.gz" "$out/share/man/man1/python.1.gz"

    # Get rid of retained dependencies on -dev packages, and remove
    # some $TMPDIR references to improve binary reproducibility.
    # Note that the .pyc file of _sysconfigdata.py should be regenerated!
    for i in $out/lib/${libPrefix}/_sysconfigdata*.py $out/lib/${libPrefix}/config-${sourceVersion.major}${sourceVersion.minor}*/Makefile; do
       sed -i $i -e "s|$TMPDIR|/no-such-path|g"
    done

    # Further get rid of references. https://github.com/NixOS/nixpkgs/issues/51668
    find $out/lib/python*/config-* -type f -print -exec nuke-refs ${keep-references} '{}' +
    find $out/lib -name '_sysconfigdata*.py*' -print -exec nuke-refs ${keep-references} '{}' +

    # Make the sysconfigdata module accessible on PYTHONPATH
    # This allows build Python to import host Python's sysconfigdata
    mkdir -p "$out/${sitePackages}"
    ln -s "$out/lib/${libPrefix}/"_sysconfigdata*.py "$out/${sitePackages}/"
    '' + optionalString stripConfig ''
    rm -R $out/bin/python*-config $out/lib/python*/config-*
    '' + optionalString stripIdlelib ''
    # Strip IDLE (and turtledemo, which uses it)
    rm -R $out/bin/idle* $out/lib/python*/{idlelib,turtledemo}
    '' + optionalString stripTkinter ''
    rm -R $out/lib/python*/tkinter
    '' + optionalString stripTests ''
    # Strip tests
    rm -R $out/lib/python*/test $out/lib/python*/**/test{,s}
    '' + optionalString includeSiteCustomize ''
    # Include a sitecustomize.py file
    cp ${../sitecustomize.py} $out/${sitePackages}/sitecustomize.py
    '' + optionalString stripBytecode ''
    # Determinism: deterministic bytecode
    # First we delete all old bytecode.
    find $out -type d -name __pycache__ -print0 | xargs -0 -I {} rm -rf "{}"
    '' + optionalString rebuildBytecode ''
    # Python 3.7 implements PEP 552, introducing support for deterministic bytecode.
    # compileall uses the therein introduced checked-hash method by default when
    # `SOURCE_DATE_EPOCH` is set.
    # We exclude lib2to3 because that's Python 2 code which fails
    # We build 3 levels of optimized bytecode. Note the default level, without optimizations,
    # is not reproducible yet. https://bugs.python.org/issue29708
    # Not creating bytecode will result in a large performance loss however, so we do build it.
    find $out -name "*.py" | ${pythonOnBuildForHostInterpreter} -m compileall -q -f -x "lib2to3" -i -
    find $out -name "*.py" | ${pythonOnBuildForHostInterpreter} -O  -m compileall -q -f -x "lib2to3" -i -
    find $out -name "*.py" | ${pythonOnBuildForHostInterpreter} -OO -m compileall -q -f -x "lib2to3" -i -
    '' + ''
    # *strip* shebang from libpython gdb script - it should be dual-syntax and
    # interpretable by whatever python the gdb in question is using, which may
    # not even match the major version of this python. doing this after the
    # bytecode compilations for the same reason - we don't want bytecode generated.
    mkdir -p $out/share/gdb
    sed '/^#!/d' Tools/gdb/libpython.py > $out/share/gdb/libpython.py

    # Disable system-wide pip installation. See https://peps.python.org/pep-0668/.
    cat <<'EXTERNALLY_MANAGED' > $out/lib/${libPrefix}/EXTERNALLY-MANAGED
    [externally-managed]
    Error=This command has been disabled as it tries to modify the immutable
     `/nix/store` filesystem.

     To use Python with Nix and nixpkgs, have a look at the online documentation:
     <https://nixos.org/manual/nixpkgs/stable/#python>.
    EXTERNALLY_MANAGED
  '' + optionalString stdenv.hostPlatform.isWindows ''
    # Shebang files that link against the build python. Shebang don’t work on windows
    rm $out/bin/2to3*
    rm $out/bin/idle*
    rm $out/bin/pydoc*

    echo linking DLLs for python’s compiled librairies
    linkDLLsInfolder $out/lib/python*/lib-dynload/
  '';

  preFixup = lib.optionalString (stdenv.hostPlatform != stdenv.buildPlatform) ''
    # Ensure patch-shebangs uses shebangs of host interpreter.
    export PATH=${lib.makeBinPath [ "$out" ]}:$PATH
  '';

  # Add CPython specific setup-hook that configures distutils.sysconfig to
  # always load sysconfigdata from host Python.
  postFixup = lib.optionalString (!stdenv.hostPlatform.isDarwin) ''
    cat << "EOF" >> "$out/nix-support/setup-hook"
    ${sysconfigdataHook}
    EOF
  '';

  # Enforce that we don't have references to the OpenSSL -dev package, which we
  # explicitly specify in our configure flags above.
  disallowedReferences = lib.optionals (openssl != null && !static && !enableFramework) [
    openssl.dev
  ] ++ lib.optionals (stdenv.hostPlatform != stdenv.buildPlatform) [
    # Ensure we don't have references to build-time packages.
    # These typically end up in shebangs.
    pythonOnBuildForHost buildPackages.bash
  ];

  separateDebugInfo = true;

  passthru = passthru // {
    doc = stdenv.mkDerivation {
      inherit src;
      name = "python${pythonVersion}-${version}-doc";

      patches = optionals (pythonAtLeast "3.9" && pythonOlder "3.10") [
        # https://github.com/python/cpython/issues/98366
        (fetchpatch {
          url = "https://github.com/python/cpython/commit/5612471501b05518287ed61c1abcb9ed38c03942.patch";
          hash = "sha256-p41hJwAiyRgyVjCVQokMSpSFg/VDDrqkCSxsodVb6vY=";
        })
      ];

      dontConfigure = true;

      dontBuild = true;

      sphinxRoot = "Doc";

      postInstallSphinx = ''
        mv $out/share/doc/* $out/share/doc/python${pythonVersion}-${version}
      '';

      nativeBuildInputs = with pkgsBuildBuild.python3.pkgs; [ sphinxHook python-docs-theme ];
    };

    tests = passthru.tests // {
      pkg-config = testers.testMetaPkgConfig finalAttrs.finalPackage;
    };
  };

  enableParallelBuilding = true;

  meta = with lib; {
    homepage = "https://www.python.org";
    changelog = let
      majorMinor = versions.majorMinor version;
      dashedVersion = replaceStrings [ "." "a" "b" ] [ "-" "-alpha-" "-beta-" ] version;
    in
      if sourceVersion.suffix == "" then
        "https://docs.python.org/release/${version}/whatsnew/changelog.html"
      else
        "https://docs.python.org/${majorMinor}/whatsnew/changelog.html#python-${dashedVersion}";
    description = "High-level dynamically-typed programming language";
    longDescription = ''
      Python is a remarkably powerful dynamic programming language that
      is used in a wide variety of application domains. Some of its key
      distinguishing features include: clear, readable syntax; strong
      introspection capabilities; intuitive object orientation; natural
      expression of procedural code; full modularity, supporting
      hierarchical packages; exception-based error handling; and very
      high level dynamic data types.
    '';
    license = licenses.psfl;
    pkgConfigModules = [ "python3" ];
    platforms = platforms.linux ++ platforms.darwin ++ platforms.windows ++ platforms.freebsd;
    mainProgram = executable;
  };
})
