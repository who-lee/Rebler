# Rebler Zygisk module - NDK build file
LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)
LOCAL_MODULE := Rebler
LOCAL_SRC_FILES := module.cpp
LOCAL_C_INCLUDES := $(LOCAL_PATH)
LOCAL_CPPFLAGS := -std=c++17 -fno-rtti -fno-exceptions -Wall -Wextra -Wno-unused-parameter
LOCAL_LDFLAGS := -Wl,-z,relro -Wl,-z,now
LOCAL_MODULE_TAGS := optional
# liblog is the only external dep (__android_log_print). -landroid/-ldl
# were never referenced — dropped so the link line is honest.
LOCAL_LDLIBS := -llog

include $(BUILD_SHARED_LIBRARY)
