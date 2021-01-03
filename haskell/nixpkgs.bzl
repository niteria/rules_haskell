"""Workspace rules (Nixpkgs)"""

load(
    "@io_tweag_rules_nixpkgs//nixpkgs:nixpkgs.bzl",
    "nixpkgs_package",
    "nixpkgs_sh_posix_configure",
)
load(
    ":private/pkgdb_to_bzl.bzl",
    "pkgdb_to_bzl",
)
load(
    ":private/workspace_utils.bzl",
    "define_rule",
    "resolve_labels",
)

def _ghc_nixpkgs_haskell_toolchain_impl(repository_ctx):
    paths = resolve_labels(repository_ctx, [
        "@rules_haskell//haskell:private/pkgdb_to_bzl.py",
    ])
    compiler_flags_select = "select({})".format(
        repository_ctx.attr.compiler_flags_select or {
            "//conditions:default": [],
        },
    )
    nixpkgs_ghc_path = repository_ctx.path(repository_ctx.attr._nixpkgs_ghc).dirname.dirname

    # Symlink content of ghc external repo. In effect, this repo has
    # the same content, but with a BUILD file that includes generated
    # content (not a static one like nixpkgs_package supports).
    for target in _find_children(repository_ctx, nixpkgs_ghc_path):
        basename = target.rpartition("/")[-1]
        repository_ctx.symlink(target, basename)

    ghc_name = "ghc-{}".format(repository_ctx.attr.version)
    result = repository_ctx.execute(["ls", "lib"])
    if result.return_code or not ghc_name in result.stdout.splitlines():
        fail(
            """\
GHC version does not match expected version.
You specified {wanted}.
Available versions:
{actual}
""".format(wanted = ghc_name, actual = result.stdout),
        )
    toolchain_libraries = pkgdb_to_bzl(repository_ctx, paths, "lib/{}".format(ghc_name))
    locale_archive = repository_ctx.attr.locale_archive
    toolchain = define_rule(
        "haskell_toolchain",
        name = "toolchain-impl",
        libraries = "toolchain_libraries",
        tools = ["@rules_haskell_ghc_nixpkgs//:bin"],
        version = repr(repository_ctx.attr.version),
        static_runtime = repository_ctx.attr.static_runtime,
        fully_static_link = repository_ctx.attr.fully_static_link,
        compiler_flags = "{} + {}".format(
            repository_ctx.attr.compiler_flags,
            compiler_flags_select,
        ),
        haddock_flags = repository_ctx.attr.haddock_flags,
        repl_ghci_args = repository_ctx.attr.repl_ghci_args,
        cabalopts = repository_ctx.attr.cabalopts,
        locale_archive = repr(locale_archive) if locale_archive else None,
        locale = repr(repository_ctx.attr.locale),
    )
    repository_ctx.file(
        "BUILD",
        executable = False,
        content = """
load(
    "@rules_haskell//haskell:defs.bzl",
    "haskell_import",
    "haskell_toolchain",
)

package(default_visibility = ["//visibility:public"])

filegroup(
    name = "bin",
    srcs = glob(["bin/*"]),
)

{haskell_toolchain_libraries}

{haskell_toolchain}
        """.format(
            haskell_toolchain_libraries = haskell_toolchain_libraries,
            haskell_toolchain = haskell_toolchain,
        ),
    )

_ghc_nixpkgs_haskell_toolchain = repository_rule(
    _ghc_nixpkgs_haskell_toolchain_impl,
    attrs = {
        # These attributes just forward to haskell_toolchain.
        # They are documented there.
        "version": attr.string(),
        "static_runtime": attr.bool(),
        "fully_static_link": attr.bool(),
        "compiler_flags": attr.string_list(),
        "compiler_flags_select": attr.string_list_dict(),
        "haddock_flags": attr.string_list(),
        "cabalopts": attr.string_list(),
        "repl_ghci_args": attr.string_list(),
        "locale_archive": attr.string(),
        # Unfortunately, repositories cannot depend on each other
        # directly. They can only depend on files inside each
        # repository. We need to be careful to depend on files that
        # change anytime any content in a repository changes, like
        # bin/ghc, which embeds the output path, which itself changes
        # if any input to the derivation changed.
        "_nixpkgs_ghc": attr.label(default = "@rules_haskell_ghc_nixpkgs//:bin/ghc"),
        "locale": attr.string(
            default = "C.UTF-8",
        ),
    },
)

def _ghc_nixpkgs_toolchain_impl(repository_ctx):
    # These constraints might look tautological, because they always
    # match the host platform if it is the same as the target
    # platform. But they are important to state because Bazel
    # toolchain resolution prefers other toolchains with more specific
    # constraints otherwise.
    target_constraints = ["@platforms//cpu:x86_64"]
    if repository_ctx.os.name == "linux":
        target_constraints.append("@platforms//os:linux")
    elif repository_ctx.os.name == "mac os x":
        target_constraints.append("@platforms//os:osx")
    exec_constraints = list(target_constraints)
    exec_constraints.append("@io_tweag_rules_nixpkgs//nixpkgs/constraints:support_nix")

    repository_ctx.file(
        "BUILD",
        executable = False,
        content = """
toolchain(
    name = "toolchain",
    toolchain_type = "@rules_haskell//haskell:toolchain",
    toolchain = "@rules_haskell_ghc_nixpkgs_haskell_toolchain//:toolchain-impl",
    exec_compatible_with = {exec_constraints},
    target_compatible_with = {target_constraints},
)
        """.format(
            exec_constraints = exec_constraints,
            target_constraints = target_constraints,
        ),
    )

_ghc_nixpkgs_toolchain = repository_rule(_ghc_nixpkgs_toolchain_impl)

def haskell_register_ghc_nixpkgs(
        version,
        is_static = None,  # DEPRECATED. See _check_static_attributes_compatibility.
        static_runtime = None,
        fully_static_link = None,
        build_file = None,
        build_file_content = None,
        compiler_flags = None,
        compiler_flags_select = None,
        haddock_flags = None,
        repl_ghci_args = None,
        cabalopts = None,
        locale_archive = None,
        attribute_path = "haskellPackages.ghc",
        sh_posix_attributes = None,
        nix_file = None,
        nix_file_deps = [],
        nixopts = None,
        locale = None,
        repositories = {},
        repository = None,
        nix_file_content = None):
    """Register a package from Nixpkgs as a toolchain.

    Toolchains can be used to compile Haskell code. To have this
    toolchain selected during [toolchain
    resolution][toolchain-resolution], set a host platform that
    includes the
    `@io_tweag_rules_nixpkgs//nixpkgs/constraints:support_nix`
    constraint value.

    [toolchain-resolution]: https://docs.bazel.build/versions/master/toolchains.html#toolchain-resolution

    ### Examples

      ```
      haskell_register_ghc_nixpkgs(
          locale_archive = "@glibc_locales//:locale-archive",
          atttribute_path = "haskellPackages.ghc",
          version = "1.2.3",   # The version of GHC
      )
      ```

      Setting the host platform can be done on the command-line like
      in the following:

      ```
      --host_platform=@io_tweag_rules_nixpkgs//nixpkgs/platforms:host
      ```

    Args:
      is_static: Deprecated. The functionality it previously gated
        (supporting GHC versions with static runtime systems) now sits under
        static_runtime, a name chosen to avoid confusion with the new flag
        fully_static_link, which controls support for fully-statically-linked
        binaries. During the deprecation period, we rewrite is_static to
        static_runtime in this macro as long as the new attributes aren't also
        used. This argument and supporting code should be removed in a future release.
      static_runtime: True if and only if a static GHC runtime is to be used. This is
        required in order to use statically-linked Haskell libraries with GHCi
        and Template Haskell.
      fully_static_link: True if and only if fully-statically-linked binaries are to be built.
      compiler_flags_select: temporary workaround to pass conditional arguments.
        See https://github.com/bazelbuild/bazel/issues/9199 for details.
      sh_posix_attributes: List of attribute paths to extract standard Unix shell tools from.
        Passed to nixpkgs_sh_posix_configure.
    """
    nixpkgs_ghc_repo_name = "rules_haskell_ghc_nixpkgs"
    nixpkgs_sh_posix_repo_name = "rules_haskell_sh_posix_nixpkgs"
    haskell_toolchain_repo_name = "rules_haskell_ghc_nixpkgs_haskell_toolchain"
    toolchain_repo_name = "rules_haskell_ghc_nixpkgs_toolchain"

    static_runtime, fully_static_link = _check_static_attributes_compatibility(
        is_static = is_static,
        static_runtime = static_runtime,
        fully_static_link = fully_static_link,
    )

    # The package from the system.
    nixpkgs_package(
        name = nixpkgs_ghc_repo_name,
        attribute_path = attribute_path,
        build_file = build_file,
        build_file_content = build_file_content,
        nix_file = nix_file,
        nix_file_deps = nix_file_deps,
        nix_file_content = nix_file_content,
        nixopts = nixopts,
        repositories = repositories,
        repository = repository,
    )

    # haskell_toolchain + haskell_import definitions.
    _ghc_nixpkgs_haskell_toolchain(
        name = haskell_toolchain_repo_name,
        version = version,
        static_runtime = static_runtime,
        fully_static_link = fully_static_link,
        compiler_flags = compiler_flags,
        compiler_flags_select = compiler_flags_select,
        haddock_flags = haddock_flags,
        cabalopts = cabalopts,
        repl_ghci_args = repl_ghci_args,
        locale_archive = locale_archive,
        locale = locale,
    )

    # toolchain definition.
    _ghc_nixpkgs_toolchain(name = toolchain_repo_name)
    native.register_toolchains("@{}//:toolchain".format(toolchain_repo_name))

    # Unix tools toolchain required for Cabal packages
    sh_posix_nixpkgs_kwargs = dict(
        nix_file_deps = nix_file_deps,
        nixopts = nixopts,
        repositories = repositories,
        repository = repository,
    )
    if sh_posix_attributes != None:
        sh_posix_nixpkgs_kwargs["packages"] = sh_posix_attributes
    nixpkgs_sh_posix_configure(
        name = nixpkgs_sh_posix_repo_name,
        **sh_posix_nixpkgs_kwargs
    )

def _check_static_attributes_compatibility(is_static, static_runtime, fully_static_link):
    """Asserts that attributes passed to `haskell_register_ghc_nixpkgs` for
    controlling use of GHC's static runtime and whether or not to build
    fully-statically-linked binaries are compatible.

    Args:
      is_static: Deprecated. The functionality it previously gated
        (supporting GHC versions with static runtime systems) now sits under
        static_runtime, a name chosen to avoid confusion with the new flag
        fully_static_link, which controls support for fully-statically-linked
        binaries. During the deprecation period, we rewrite is_static to
        static_runtime in this macro as long as the new attributes aren't also
        used. This argument and supporting code should be removed in a future release.
      static_runtime: True if and only if a static GHC runtime is to be used. This is
        required in order to use statically-linked Haskell libraries with GHCi
        and Template Haskell.
      fully_static_link: True if and only if fully-statically-linked binaries are to be built.

    Returns:
      A tuple of static_runtime, fully_static_link attributes, which are guaranteed
      not to be None, taking into account the deprecated is_static argument.
    """

    # Check for use of the deprecated `is_static` attribute.
    if is_static != None:
        if static_runtime != None or fully_static_link != None:
            fail("is_static is deprecated. Please use the static_runtime attribute instead.")

        print("WARNING: is_static is deprecated. Please use the static_runtime attribute instead.")
        static_runtime = is_static

    # Currently we do not support the combination of a dynamic runtime system
    # and fully-statically-linked binaries, so fail if this has been selected.
    if not static_runtime and fully_static_link:
        fail(
            """\
Fully-statically-linked binaries with a dynamic runtime are not currently supported.
Please pass static_runtime = True if you wish to build fully-statically-linked binaries.
""",
        )

    return bool(static_runtime), bool(fully_static_link)

def _find_children(repository_ctx, target_dir):
    find_args = [
        "find",
        "-L",
        target_dir,
        "-maxdepth",
        "1",
        # otherwise the directory is printed as well
        "-mindepth",
        "1",
        # filenames can contain \n
        "-print0",
    ]
    exec_result = repository_ctx.execute(find_args)
    if exec_result.return_code:
        fail("_find_children() failed.")
    return exec_result.stdout.rstrip("\0").split("\0")
