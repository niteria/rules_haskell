load("@bazel_skylib//lib:dicts.bzl", "dicts")
load(
    "@io_tweag_rules_haskell//haskell:private/providers.bzl",
    "CcSkylarkApiProviderHacked",
    "HaskellBinaryInfo",
    "HaskellBuildInfo",
    "HaskellLibraryInfo",
    "HaskellPrebuiltPackageInfo",
)
load(
    ":private/path_utils.bzl",
    "is_shared_library",
    "is_static_library",
    "ln",
)
load(":private/set.bzl", "set")

def _mangle_lib(ctx, label, lib, preserve_name):
    """Create a symlink to a library, with a longer name.

    The built-in cc_* rules don't link against a library
    directly. They link against a symlink whose name is guaranteed to be
    unique across the entire workspace. This disambiguates
    libraries with the same name. This process is called "mangling".
    The built-in rules don't expose mangling functionality directly (see
    https://github.com/bazelbuild/bazel/issues/4581). But this function
    emulates the built-in dynamic library mangling.

    Args:
      ctx: Rule context.
      label: the label to use as a qualifier for the library name.
      solib: the library.
      preserve_name: Bool, whether given `lib` should be returned unchanged.

    Returns:
      File: the created symlink or the original lib.
    """

    if preserve_name:
        return lib

    components = [c for c in [label.workspace_root, label.package, label.name] if c]
    qualifier = "/".join(components).replace("_", "_U").replace("/", "_S")
    quallib = ctx.actions.declare_file("lib" + qualifier + "_" + lib.basename)

    ln(ctx, lib, quallib)

    return quallib

def gather_dep_info(ctx):
    """Collapse dependencies into a single `HaskellBuildInfo`.

    Note that the field `prebuilt_dependencies` also includes
    prebuilt_dependencies of current target.

    Args:
      ctx: Rule context.

    Returns:
      HaskellBuildInfo: Unified information about all dependencies.
    """

    acc = HaskellBuildInfo(
        package_ids = set.empty(),
        package_confs = set.empty(),
        package_caches = set.empty(),
        static_libraries = [],
        static_libraries_prof = [],
        dynamic_libraries = set.empty(),
        interface_dirs = set.empty(),
        prebuilt_dependencies = set.empty(),
        # a set of struct(lib, mangled_lib)
        external_libraries = set.empty(),
        direct_prebuilt_deps = set.empty(),
        extra_libraries = set.empty(),
    )

    for dep in ctx.attr.deps:
        if HaskellBuildInfo in dep:
            binfo = dep[HaskellBuildInfo]
            package_ids = acc.package_ids
            if HaskellBinaryInfo in dep:
                fail("Target {0} cannot depend on binary".format(ctx.attr.name))
            if HaskellLibraryInfo in dep:
                set.mutable_insert(package_ids, dep[HaskellLibraryInfo].package_id)
            acc = HaskellBuildInfo(
                package_ids = package_ids,
                package_confs = set.mutable_union(acc.package_confs, binfo.package_confs),
                package_caches = set.mutable_union(acc.package_caches, binfo.package_caches),
                static_libraries = acc.static_libraries + binfo.static_libraries,
                static_libraries_prof = acc.static_libraries_prof + binfo.static_libraries_prof,
                dynamic_libraries = set.mutable_union(acc.dynamic_libraries, binfo.dynamic_libraries),
                interface_dirs = set.mutable_union(acc.interface_dirs, binfo.interface_dirs),
                prebuilt_dependencies = set.mutable_union(acc.prebuilt_dependencies, binfo.prebuilt_dependencies),
                external_libraries = set.mutable_union(acc.external_libraries, binfo.external_libraries),
                direct_prebuilt_deps = acc.direct_prebuilt_deps,
                extra_libraries = acc.extra_libraries,
            )
        elif HaskellPrebuiltPackageInfo in dep:
            pkg = dep[HaskellPrebuiltPackageInfo]
            acc = HaskellBuildInfo(
                package_ids = acc.package_ids,
                package_confs = acc.package_confs,
                package_caches = acc.package_caches,
                static_libraries = acc.static_libraries,
                static_libraries_prof = acc.static_libraries_prof,
                dynamic_libraries = acc.dynamic_libraries,
                interface_dirs = acc.interface_dirs,
                prebuilt_dependencies = set.mutable_insert(acc.prebuilt_dependencies, pkg),
                external_libraries = acc.external_libraries,
                direct_prebuilt_deps = set.mutable_insert(acc.direct_prebuilt_deps, pkg),
                extra_libraries = acc.extra_libraries,
            )
        else:
            # The final link of a library must include all static
            # libraries we depend on, including transitives ones.
            # Theses libs are provided in `dep.cc.libs` attribute.
            transitive_static_deps = set.empty()

            # Transitive static dependencies
            if hasattr(dep, "cc"):
                transitive_static_deps = set.from_list([
                    struct(
                        lib = name,
                        mangled_lib = _mangle_lib(ctx, dep.label, name, CcSkylarkApiProviderHacked in dep),
                    )
                    for name in dep.cc.libs.to_list()
                    if is_static_library(name)
                ])

            # Transitive dynamic dependencies
            # Note, this can include dynamic versions of items in
            # transitive_static_deps.
            # If the provider is CcSkylarkApiProviderHacked, then the .so
            # files come from haskell_cc_import.
            cc_skylark_api_hack_deps = set.from_list([
                struct(
                    lib = f,
                    mangled_lib = _mangle_lib(ctx, dep.label, f, CcSkylarkApiProviderHacked in dep),
                )
                for f in dep.files.to_list()
                if is_shared_library(f)
            ])

            # If not a Haskell dependency, pass it through as-is to the
            # linking phase.
            acc = HaskellBuildInfo(
                package_ids = acc.package_ids,
                package_confs = acc.package_confs,
                package_caches = acc.package_caches,
                static_libraries = acc.static_libraries,
                static_libraries_prof = acc.static_libraries_prof,
                dynamic_libraries = acc.dynamic_libraries,
                interface_dirs = acc.interface_dirs,
                prebuilt_dependencies = acc.prebuilt_dependencies,
                external_libraries = set.mutable_union(
                    set.mutable_union(
                        acc.external_libraries,  # this is the mutated set
                        cc_skylark_api_hack_deps,
                    ),
                    transitive_static_deps,
                ),
                direct_prebuilt_deps = acc.direct_prebuilt_deps,
                extra_libraries = set.mutable_union(
                    acc.extra_libraries,
                    transitive_static_deps,
                ),
            )

    return acc
