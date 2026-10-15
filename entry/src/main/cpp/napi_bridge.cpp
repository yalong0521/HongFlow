#include "napi/native_api.h"
#include <cerrno>
#include <cmath>
#include <cstring>
#include <dlfcn.h>
#include <limits>
#include <mutex>
#include <string>

#if defined(__linux__)
#include <linux/if_tun.h>
#include <net/if.h>
#include <sys/ioctl.h>
#endif

namespace {
using ValidateFunction = char *(*)(const char *);
using StartFunction = char *(*)(const char *, const char *, int, const char *);
using StringFunction = char *(*)();
using FreeFunction = void (*)(void *);
using ModeFunction = char *(*)(const char *, const char *);

struct CoreLibrary {
  void *handle = nullptr;
  std::string error;
  ValidateFunction validate = nullptr;
  StartFunction start = nullptr;
  StringFunction stop = nullptr;
  StringFunction version = nullptr;
  FreeFunction freeString = nullptr;
  ModeFunction setMode = nullptr;
};

CoreLibrary library;
std::mutex libraryMutex;

std::string LoadCore() {
  std::lock_guard<std::mutex> guard(libraryMutex);
  if (library.handle != nullptr) {
    return library.error;
  }
  void *handle = dlopen("libhongflow_core.so", RTLD_NOW | RTLD_LOCAL);
  if (handle == nullptr) {
    const char *error = dlerror();
    return std::string("无法加载 VPN 内核: ") + (error == nullptr ? "unknown" : error);
  }
  // Loading starts the Go runtime before symbol lookup. Keep its handle even
  // for an incompatible library so its background threads remain mapped.
  library.handle = handle;
  library.validate = reinterpret_cast<ValidateFunction>(dlsym(handle, "HongFlowValidate"));
  library.start = reinterpret_cast<StartFunction>(dlsym(handle, "HongFlowStart"));
  library.stop = reinterpret_cast<StringFunction>(dlsym(handle, "HongFlowStop"));
  library.version = reinterpret_cast<StringFunction>(dlsym(handle, "HongFlowVersion"));
  library.freeString = reinterpret_cast<FreeFunction>(dlsym(handle, "HongFlowFree"));
  library.setMode = reinterpret_cast<ModeFunction>(dlsym(handle, "HongFlowSetMode"));
  if (!library.validate || !library.start || !library.stop || !library.version ||
      !library.freeString || !library.setMode) {
    library.error = "VPN 内核接口不完整";
    return library.error;
  }
  return "";
}

std::string TakeString(char *value) {
  if (value == nullptr) {
    return "VPN 内核没有返回结果";
  }
  const std::string result(value);
  library.freeString(value);
  return result;
}

bool GetString(napi_env env, napi_value value, std::string &result) {
  size_t size = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &size) != napi_ok ||
      size > 5 * 1024 * 1024) {
    napi_throw_type_error(env, nullptr, "字符串参数无效或超过 5 MB");
    return false;
  }
  result.resize(size + 1);
  if (napi_get_value_string_utf8(env, value, result.data(), result.size(), &size) != napi_ok) {
    napi_throw_type_error(env, nullptr, "字符串参数无效");
    return false;
  }
  result.resize(size);
  // The C ABI consumes null-terminated strings; reject truncation before validation.
  if (result.find('\0') != std::string::npos) {
    napi_throw_type_error(env, nullptr, "字符串参数不能包含空字符");
    return false;
  }
  return true;
}

enum class Operation { VALIDATE, START, STOP, MODE };

struct AsyncCall {
  napi_async_work work = nullptr;
  napi_deferred deferred = nullptr;
  Operation operation = Operation::STOP;
  std::string first;
  std::string second;
  std::string secret;
  int fd = -1;
  std::string result;
  std::string error;
};

void Execute(napi_env, void *data) {
  auto *call = static_cast<AsyncCall *>(data);
  call->error = LoadCore();
  if (!call->error.empty()) {
    return;
  }
  switch (call->operation) {
  case Operation::VALIDATE:
    call->result = TakeString(library.validate(call->first.c_str()));
    break;
  case Operation::START:
    call->error = TakeString(
        library.start(call->first.c_str(), call->second.c_str(), call->fd, call->secret.c_str()));
    break;
  case Operation::STOP:
    call->error = TakeString(library.stop());
    break;
  case Operation::MODE:
    call->error = TakeString(library.setMode(call->first.c_str(), call->secret.c_str()));
    break;
  }
}

void Complete(napi_env env, napi_status status, void *data) {
  auto *call = static_cast<AsyncCall *>(data);
  if (status != napi_ok && call->error.empty()) {
    call->error = "VPN 内核操作已取消";
  }
  napi_value value = nullptr;
  if (!call->error.empty()) {
    napi_value message = nullptr;
    napi_create_string_utf8(env, call->error.c_str(), NAPI_AUTO_LENGTH, &message);
    napi_create_error(env, nullptr, message, &value);
    napi_reject_deferred(env, call->deferred, value);
  } else {
    if (call->operation == Operation::VALIDATE) {
      napi_create_string_utf8(env, call->result.c_str(), call->result.size(), &value);
    } else {
      napi_get_undefined(env, &value);
    }
    napi_resolve_deferred(env, call->deferred, value);
  }
  napi_delete_async_work(env, call->work);
  delete call;
}

napi_value Queue(napi_env env, AsyncCall *call) {
  napi_value promise = nullptr;
  napi_value name = nullptr;
  napi_create_promise(env, &call->deferred, &promise);
  napi_create_string_utf8(env, "HongFlowCore", NAPI_AUTO_LENGTH, &name);
  if (napi_create_async_work(env, nullptr, name, Execute, Complete, call, &call->work) != napi_ok ||
      napi_queue_async_work(env, call->work) != napi_ok) {
    napi_value message = nullptr;
    napi_value error = nullptr;
    napi_create_string_utf8(env, "无法调度 VPN 内核操作", NAPI_AUTO_LENGTH, &message);
    napi_create_error(env, nullptr, message, &error);
    napi_reject_deferred(env, call->deferred, error);
    if (call->work != nullptr) {
      napi_delete_async_work(env, call->work);
    }
    delete call;
  }
  return promise;
}

napi_value Validate(napi_env env, napi_callback_info info) {
  size_t count = 1;
  napi_value args[1];
  napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
  if (count != 1) {
    napi_throw_type_error(env, nullptr, "配置内容参数缺失");
    return nullptr;
  }
  auto *call = new AsyncCall;
  call->operation = Operation::VALIDATE;
  if (!GetString(env, args[0], call->first)) {
    delete call;
    return nullptr;
  }
  return Queue(env, call);
}

napi_value Start(napi_env env, napi_callback_info info) {
  size_t count = 4;
  napi_value args[4];
  napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
  auto *call = new AsyncCall;
  call->operation = Operation::START;
  if (count != 4 || !GetString(env, args[0], call->first) ||
      !GetString(env, args[1], call->second) ||
      napi_get_value_int32(env, args[2], &call->fd) != napi_ok || call->fd < 0 ||
      !GetString(env, args[3], call->secret)) {
    delete call;
    napi_throw_type_error(env, nullptr, "VPN 启动参数无效");
    return nullptr;
  }
  return Queue(env, call);
}

napi_value Stop(napi_env env, napi_callback_info) { return Queue(env, new AsyncCall); }

napi_value TunInterfaceName(napi_env env, napi_callback_info info) {
  size_t count = 2;
  napi_value args[2];
  double fd = -1;
  int descriptor = -1;
  if (napi_get_cb_info(env, info, &count, args, nullptr, nullptr) != napi_ok || count != 1 ||
      napi_get_value_double(env, args[0], &fd) != napi_ok || !std::isfinite(fd) || fd < 0 ||
      fd > std::numeric_limits<int>::max() || std::floor(fd) != fd ||
      napi_get_value_int32(env, args[0], &descriptor) != napi_ok) {
    napi_throw_type_error(env, nullptr, "TUN 文件描述符参数无效");
    return nullptr;
  }
#if defined(__linux__)
  // Read the interface owned by this descriptor; a guessed name could identify another VPN.
  struct ifreq request = {};
  int result;
  do {
    result = ioctl(descriptor, TUNGETIFF, &request);
  } while (result < 0 && errno == EINTR);
  if (result < 0) {
    const auto error = std::string("读取 TUN 网卡名称失败: ") + std::strerror(errno);
    napi_throw_error(env, nullptr, error.c_str());
    return nullptr;
  }
  const size_t length = strnlen(request.ifr_name, IFNAMSIZ);
  if (length == 0 || length == IFNAMSIZ) {
    napi_throw_error(env, nullptr, "TUN 网卡名称无效");
    return nullptr;
  }
  napi_value name = nullptr;
  napi_create_string_utf8(env, request.ifr_name, length, &name);
  return name;
#else
  napi_throw_error(env, nullptr, "当前平台不支持读取 TUN 网卡名称");
  return nullptr;
#endif
}

napi_value Version(napi_env env, napi_callback_info) {
  const auto error = LoadCore();
  if (!error.empty()) {
    napi_throw_error(env, nullptr, error.c_str());
    return nullptr;
  }
  const auto result = TakeString(library.version());
  napi_value value = nullptr;
  napi_create_string_utf8(env, result.c_str(), result.size(), &value);
  return value;
}

napi_value SetMode(napi_env env, napi_callback_info info) {
  size_t count = 2;
  napi_value args[2];
  napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
  if (count != 2) {
    napi_throw_type_error(env, nullptr, "代理模式或控制密钥参数缺失");
    return nullptr;
  }
  auto *call = new AsyncCall;
  call->operation = Operation::MODE;
  if (!GetString(env, args[0], call->first) || !GetString(env, args[1], call->secret)) {
    delete call;
    return nullptr;
  }
  return Queue(env, call);
}

napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor descriptors[] = {
      {"validateProfile", nullptr, Validate, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"tunInterfaceName", nullptr, TunInterfaceName, nullptr, nullptr, nullptr, napi_default,
       nullptr},
      {"version", nullptr, Version, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"setMode", nullptr, SetMode, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
  return exports;
}

napi_module module = {1, 0, nullptr, Init, "hongflowbridge", nullptr, {nullptr}};
} // namespace

extern "C" __attribute__((constructor)) void RegisterHongFlowModule() {
  napi_module_register(&module);
}
