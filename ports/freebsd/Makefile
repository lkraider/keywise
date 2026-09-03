PORTNAME=	keywise
DISTVERSION=	2.4.0
CATEGORIES=	security

MAINTAINER=	paul@institutoprojetodevida.org
COMMENT=	Terminal UI to view a local Firefox profile's saved logins
WWW=		https://github.com/lkraider/keywise

LICENSE=	MIT
LICENSE_FILE=	${WRKSRC}/LICENSE

USES=		zig

USE_GITHUB=	yes
GH_ACCOUNT=	lkraider

ZIG_TUPLE=	libvaxis:github.com/rockorager/libvaxis/archive/6cab03f8a3faeb58bddf334343889a7f685ba7a7.tar.gz:vaxis-0.6.0-BWNV_FcoCgB3Q_LTiQet_GeS23Bd7e224eHloS8PanKZ

PLIST_FILES=	bin/${PORTNAME}

.include <bsd.port.mk>
