extends RefCounted

# 发布版本信息元数据。
# 供主菜单与信息界面展示。打包发布时由构建工具写入具体版本与时间戳。
# 源码库中默认保持为开发占位状态。
const VERSION := "dev"
const BUILD_STAMP := ""


# 获取格式化展示文本：发布版返回完整标识，开发版返回 dev 由调用方回退至 Git 信息。
static func display() -> String:
	if VERSION.is_empty() or VERSION == "dev":
		return "dev"
	return VERSION if BUILD_STAMP.is_empty() else "%s_%s" % [VERSION, BUILD_STAMP]
