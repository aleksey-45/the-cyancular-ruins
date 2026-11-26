#ifdef _WIN32
#include "process_group_windows.hpp"
#else
#include "process_group_macos.hpp"
#endif

void OwnedProcessGroup::_bind_methods() {
	ClassDB::bind_method(D_METHOD("launch", "path", "arguments", "capture"), &OwnedProcessGroup::launch);
	ClassDB::bind_method(D_METHOD("running", "pid"), &OwnedProcessGroup::running);
	ClassDB::bind_method(D_METHOD("poll", "pid"), &OwnedProcessGroup::poll);
	ClassDB::bind_method(D_METHOD("stop", "pid"), &OwnedProcessGroup::stop);
	ClassDB::bind_method(D_METHOD("stop_all"), &OwnedProcessGroup::stop_all);
}

static void initialize(ModuleInitializationLevel level) {
	if (level == MODULE_INITIALIZATION_LEVEL_SCENE) GDREGISTER_CLASS(OwnedProcessGroup);
}

extern "C" GDExtensionBool GDE_EXPORT process_group_init(GDExtensionInterfaceGetProcAddress get_proc_address,
		GDExtensionClassLibraryPtr library, GDExtensionInitialization *initialization) {
	GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
	init.register_initializer(initialize);
	init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init.init();
}
