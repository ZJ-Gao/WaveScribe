// The punctuation part of the sherpa-onnx C API (sherpa-onnx/c-api/c-api.h, v2.0.1).
// The library is loaded at runtime with dlopen, so only the struct layouts and function types are declared here.
#pragma once
#include <stdint.h>

typedef struct SherpaOnnxOfflinePunctuationModelConfig {
  const char *ct_transformer;
  int32_t num_threads;
  int32_t debug;
  const char *provider;
} SherpaOnnxOfflinePunctuationModelConfig;

typedef struct SherpaOnnxOfflinePunctuationConfig {
  SherpaOnnxOfflinePunctuationModelConfig model;
} SherpaOnnxOfflinePunctuationConfig;

typedef const void *(*SherpaCreatePunctFn)(const SherpaOnnxOfflinePunctuationConfig *config);
typedef void (*SherpaDestroyPunctFn)(const void *punct);
typedef const char *(*SherpaAddPunctFn)(const void *punct, const char *text);
typedef void (*SherpaFreeTextFn)(const char *text);
