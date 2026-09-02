COMMENT =	terminal UI to view a local Firefox profile's saved logins

V =		2.3.0

GH_ACCOUNT =	lkraider
GH_PROJECT =	keywise
GH_TAGNAME =	v${V}

CATEGORIES =	security

HOMEPAGE =	https://github.com/lkraider/keywise

# MIT
PERMIT_PACKAGE = Yes

LV_COMMIT =	6cab03f8a3faeb58bddf334343889a7f685ba7a7
LV_HASH =	vaxis-0.6.0-BWNV_FcoCgB3Q_LTiQet_GeS23Bd7e224eHloS8PanKZ
SITES.lv =	https://github.com/rockorager/libvaxis/archive/
DISTFILES.lv =	${LV_COMMIT}.tar.gz

BUILD_DEPENDS =	lang/zig>=0.16.0

WRKDIST =	${WRKDIR}/keywise-${V}

NO_TEST =	Yes

do-build:
	mkdir -p ${WRKDIR}/.deps
	mv ${WRKDIR}/libvaxis-${LV_COMMIT} ${WRKDIR}/.deps/${LV_HASH}
	cd ${WRKDIST} && ${LOCALBASE}/bin/zig build \
		--system ${WRKDIR}/.deps \
		-Doptimize=ReleaseSafe

do-install:
	${INSTALL_PROGRAM} ${WRKDIST}/zig-out/bin/keywise ${PREFIX}/bin/

.include <bsd.port.mk>
