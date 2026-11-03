extends RefCounted

# 发布版本信息(**单一来源**)。主菜单那行版本号读这里。
const VERSION := "dev"
const BUILD_STAMP := ""


# 展示串:发布版 = "RoF_v0.5.0_202610040204",开发版 = "dev"(调用方据此决定是否回落到 git)。
static func display() -> String:
	if VERSION.is_empty() or VERSION == "dev":
		return "dev"
	return VERSION if BUILD_STAMP.is_empty() else "%s_%s" % [VERSION, BUILD_STAMP]
