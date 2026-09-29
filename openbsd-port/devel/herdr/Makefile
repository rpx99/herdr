COMMENT =	terminal workspace manager for AI coding agents
V =		0.9.3
DISTNAME =	herdr-${V}
DISTFILES =	${DISTNAME}${EXTRACT_SUFX}
PKGNAME =	herdr-${V}
CATEGORIES =	devel
HOMEPAGE =	https://herdr.dev
MAINTAINER =	Robert Palm <developer@robert-palm.de>

# Apache-2.0
PERMIT_PACKAGE =	Yes

# Pure Rust plus the vendored libghostty-vt (Zig) built via zig(1) 0.16:
# BUILD_DEPENDS += lang/zig (or point ZIG at a user-local zig 0.16 binary).
WANTLIB =	c pthread
COMPILER =	base-clang

MODULES =	devel/cargo
CONFIGURE_STYLE =	cargo
# Path to the zig 0.16 binary used by the vendored libghostty-vt build.rs.
ZIG_BIN ?=	zig
# Ports sandbox HOME is not writable; keep zig caches inside the workdir.
MAKE_ENV +=	ZIG="${ZIG_BIN}" \
		ZIG_GLOBAL_CACHE_DIR="${WRKDIR}/zig-global-cache" \
		ZIG_LOCAL_CACHE_DIR="${WRKDIR}/zig-local-cache"
MODCARGO_BUILD_ARGS =	--bin herdr
.include "crates.inc"

do-install:
	${INSTALL_PROGRAM} ${MODCARGO_TARGET_DIR}/release/herdr ${PREFIX}/bin/herdr

.include <bsd.port.mk>
