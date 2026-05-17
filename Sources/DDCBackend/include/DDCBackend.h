#ifndef DDCBACKEND_H
#define DDCBACKEND_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DCL_MAX_DISPLAYS 16
#define DCL_STRING_SIZE 256

typedef struct {
    uint32_t runtimeDisplayID;
    uint32_t vendorID;
    uint32_t modelID;
    uint32_t serialNumber;
    bool isBuiltIn;
    bool isActive;
    char systemUUID[DCL_STRING_SIZE];
    char edidUUID[DCL_STRING_SIZE];
    char displayName[DCL_STRING_SIZE];
    char manufacturer[DCL_STRING_SIZE];
    char alphanumericSerial[DCL_STRING_SIZE];
    char ioLocation[DCL_STRING_SIZE];
} DCLDisplayInfo;

typedef enum {
    DCLStatusOK = 0,
    DCLStatusNoDisplay = 1,
    DCLStatusNoAVService = 2,
    DCLStatusDDCWriteFailed = 3,
    DCLStatusDDCReadFailed = 4,
    DCLStatusInvalidArgument = 5,
    DCLStatusMissingPrivateAPI = 6,
    DCLStatusDisplayConfigFailed = 7
} DCLStatus;

typedef struct {
    DCLStatus status;
    int currentValue;
    int maxValue;
} DCLVCPReadResult;

int DCLCopyOnlineDisplays(DCLDisplayInfo *buffer, int capacity);
DCLStatus DCLSetDisplayEnabled(uint32_t runtimeDisplayID, bool enabled);
DCLVCPReadResult DCLReadVCPByEDID(const char *edidUUID, uint8_t vcpCode);
DCLStatus DCLWriteVCPByEDID(const char *edidUUID, uint8_t vcpCode, uint8_t value);
const char *DCLStatusDescription(DCLStatus status);

#ifdef __cplusplus
}
#endif

#endif
