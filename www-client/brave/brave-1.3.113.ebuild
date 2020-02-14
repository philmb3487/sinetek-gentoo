# Copyright 2020 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=7

PYTHON_COMPAT=( python2_7 )

inherit git-r3 python-any-r1 flag-o-matic desktop xdg-utils

DESCRIPTION="Brave is a free and open-source web browser"
HOMEPAGE="https://brave.com/"
EGIT_REPO_URI="https://github.com/brave/brave-browser"
EGIT_COMMIT="v1.3.113"
EGIT_SUBMODULES=()

LICENSE="MPL-2.0"
SLOT="0"
KEYWORDS="amd64"
IUSE="+closure-compile cups gnome-keyring kerberos pulseaudio +hangouts +tcmalloc +widevine -system-icu"

## ISSUES.
# 
# * right now the ebuild does not check for sufficient disk and storage space.
# * there is a way to generate the desktop file directly from source.
# * dependencies are very poorly taken care of right now.
# * the older versions of sandbox segfault. we need >= 2.17.
# * cross-compilation probably does not work.

# FEATURES="keepwork" can be used to avoid re-downloading the complete source code,
# which as of the time of writing this is around 20 GB in total.

DEPEND="
	system-icu? ( dev-libs/icu )
	dev-libs/libxml2
"
RDEPEND="${DEPEND}"
BDEPEND="
	${PYTHON_DEPS}
	=sys-apps/sandbox-2.17
	net-libs/nodejs
"

PATCHES=(
	"${FILESDIR}/chromium-compiler-r10.patch"
	"${FILESDIR}/chromium-fix-char_traits.patch"
#	"${FILESDIR}/chromium-unbundle-zlib-r1.patch"
	"${FILESDIR}/chromium-77-system-icu.patch"
	"${FILESDIR}/chromium-78-protobuf-export.patch"
	"${FILESDIR}/chromium-79-gcc-alignas.patch"
	"${FILESDIR}/chromium-80-unbundle-libxml.patch"
	"${FILESDIR}/chromium-80-include.patch"
	"${FILESDIR}/chromium-80-gcc-quiche.patch"
	"${FILESDIR}/chromium-80-gcc-permissive.patch"
	"${FILESDIR}/chromium-80-gcc-blink.patch"
	"${FILESDIR}/chromium-80-gcc-abstract.patch"
	"${FILESDIR}/chromium-80-gcc-incomplete-type.patch"

	"${FILESDIR}/relic-intrin.patch"
	"${FILESDIR}/brave-content_settings-redirect.patch"
	"${FILESDIR}/brave-misc.patch"
)

src_unpack() {
	git-r3_src_unpack
}

src_prepare() {
	python_setup

	# npm is used to fetch the brave base portion of the source.
	# note that the download is very big, around 19 GB.
	npm install || die
	npm run init || die
	#npm run sync -- --all --run_hooks --run_sync || npm run init || die

	# ... and the patches
	sed -i -e "/\/\/chrome\/installer\/linux/d" src/brave/BUILD.gn || die
	cd src
	default
}

src_configure() {
	python_setup

	local myconf_gn=""

	# make sure the build system will use the right tools, bug #340795.
	tc-export AR CC CXX NM

	# use gcc.
	myconf_gn+=" is_clang: false,"
	myconf_gn+=" is_cfi: false,"
	myconf_gn+=" is_debug: false,"

	# use the system toolchain.
	myconf_gn+=" custom_toolchain: \"//build/toolchain/linux/unbundle:default\","
	myconf_gn+=" host_toolchain: \"//build/toolchain/linux/unbundle:default\","

	# component build isn't generally intended for use by end users. It's mostly useful
	# for development and debugging.
	myconf_gn+=" is_component_build: false,"

	myconf_gn+=" use_allocator: $(usex tcmalloc \"tcmalloc\" \"none\"),"

	# nacl will be deprecated soon.
	myconf_gn+=" enable_nacl: false,"

	#myconf_gn+=" system_harfbuzz: true,"

	# explicitly disable ICU data file support for system-icu builds.
	if use system-icu; then
		myconf_gn+=" icu_use_data_file: false,"
	fi

	# prevent the linker from running out of memory.
	myconf_gn+=" blink_symbol_level: 0,"
	myconf_gn+=" symbol_level: 0,"

	# optional dependencies.
	myconf_gn+=" closure_compile: $(usex closure-compile true false),"
	myconf_gn+=" enable_hangout_services_extension: $(usex hangouts true false),"
	myconf_gn+=" enable_widevine: $(usex widevine true false),"
	myconf_gn+=" use_cups: $(usex cups true false),"
	myconf_gn+=" use_gnome_keyring: $(usex gnome-keyring true false),"
	myconf_gn+=" use_kerberos: $(usex kerberos true false),"
	myconf_gn+=" use_pulseaudio: $(usex pulseaudio true false),"

	myconf_gn+=" fieldtrial_testing_like_official_build: true,"

	# don't use bundled toolchain.
	myconf_gn+=" use_gold: false,"
	myconf_gn+=" use_sysroot: false,"
	myconf_gn+=" linux_use_bundled_binutils: false,"
	myconf_gn+=" use_custom_libcxx: false,"

	# disable forced lld
	myconf_gn+=" use_lld: false,"

	# warnings vary depending on the compiler used, and the version,
	# we don't want the build to fail because of that.
	myconf_gn+=" treat_warnings_as_errors: false,"

	# Disable fatal linker warnings, bug 506268.
	myconf_gn+=" fatal_linker_warnings: false,"

	echo ${myconf_gn}

	# configure brave.
	sed -i -e "s|this.extraGnArgs = {}|this.extraGnArgs = {${myconf_gn}}|" lib/config.js || die

	# make the build verbose.
	sed -i -e "s|this.extraNinjaOpts = \[\]|this.extraNinjaOpts = \['-v'\]|" lib/config.js || die
}

src_compile() {
	python_setup

	# final link uses lots of file descriptors.
	ulimit -n 4096

	npm run build Release || die
}

src_install() {
	local BRAVE_HOME
	BRAVE_HOME="/usr/$(get_libdir)/brave"

	exeinto ${BRAVE_HOME}
	doexe src/out/Release/brave
	dosym ${BRAVE_HOME}/brave /usr/bin/${PN} || die

	insinto ${BRAVE_HOME}
	doins src/out/Release/*.bin
	doins src/out/Release/*.pak
	doins src/out/Release/*.so

	if ! use system-icu; then
		doins src/out/Release/icudtl.dat
	fi

	doins -r src/out/Release/locales
	doins -r src/out/Release/resources

	if [[ -d out/Release/swiftshader ]]; then
		insinto "${BRAVE_HOME}/swiftshader"
		doins src/out/Release/swiftshader/*.so
	fi

	# install icons
	local branding size
	for size in 16 24 32 48 64 128 256 ; do
		case ${size} in
			16|32) branding="brave/app/theme/default_100_percent/brave" ;;
			*) branding="brave/app/theme/brave" ;;
		esac
		newicon -s ${size} "src/${branding}/product_logo_${size}.png" ${PN}.png
	done

	domenu "${FILESDIR}"/${PN}.desktop
}

pkg_postrm() {
	xdg_icon_cache_update
	xdg_desktop_database_update
}

pkg_postinst() {
	xdg_icon_cache_update
	xdg_desktop_database_update
}
