#import "DDCBackend.h"

#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <unistd.h>

typedef CFTypeRef IOAVServiceRef;

extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceReadI2C(IOAVServiceRef service, uint32_t chipAddress, uint32_t offset, void *outputBuffer, uint32_t outputBufferSize);
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef service, uint32_t chipAddress, uint32_t dataAddress, void *inputBuffer, uint32_t inputBufferSize);
extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID display);

typedef CGError (*DCLCGSConfigureDisplayEnabledFn)(CGDisplayConfigRef config, CGDirectDisplayID display, bool enabled);

static const uint8_t DCLDefaultInputAddress = 0x51;
static const uint8_t DCLAlternateInputAddress = 0x50;
static const uint8_t DCLAlternateInputVCP = 0xF4;
static const useconds_t DCLDDCWaitMicroseconds = 50000;
static const int DCLDDCIterations = 2;
static const int DCLDDCBufferSize = 256;

typedef struct {
    uint8_t data[256];
    uint8_t inputAddress;
} DCLDDCPacket;

typedef struct {
    int currentValue;
    int maxValue;
} DCLDDCValue;

static void DCLCopyCString(NSString *source, char destination[DCL_STRING_SIZE]) {
    memset(destination, 0, DCL_STRING_SIZE);
    if (source.length == 0) {
        return;
    }
    const char *utf8 = source.UTF8String;
    if (utf8 == NULL) {
        return;
    }
    strlcpy(destination, utf8, DCL_STRING_SIZE);
}

static NSString *DCLStringFromCFType(CFTypeRef value) {
    if (value == NULL) {
        return @"";
    }
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        return (__bridge NSString *)value;
    }
    return [NSString stringWithFormat:@"%@", value];
}

static CFTypeRef DCLCopyRegistryProperty(io_service_t service, const char *key) {
    CFStringRef cfKey = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingASCII);
    if (cfKey == NULL) {
        return NULL;
    }
    CFTypeRef value = IORegistryEntrySearchCFProperty(service, kIOServicePlane, cfKey, kCFAllocatorDefault, kIORegistryIterateRecursively);
    CFRelease(cfKey);
    return value;
}

static void DCLFillDisplayInfo(CGDirectDisplayID displayID, DCLDisplayInfo *info) {
    memset(info, 0, sizeof(DCLDisplayInfo));
    info->runtimeDisplayID = displayID;
    info->serialNumber = CGDisplaySerialNumber(displayID);
    info->modelID = CGDisplayModelNumber(displayID);
    info->vendorID = CGDisplayVendorNumber(displayID);
    info->isBuiltIn = CGDisplayIsBuiltin(displayID);
    info->isActive = CGDisplayIsActive(displayID);

    CFDictionaryRef displayDictionary = CoreDisplay_DisplayCreateInfoDictionary(displayID);
    NSString *ioLocation = @"";
    if (displayDictionary != NULL) {
        DCLCopyCString(DCLStringFromCFType(CFDictionaryGetValue(displayDictionary, CFSTR("kCGDisplayUUID"))), info->systemUUID);
        ioLocation = DCLStringFromCFType(CFDictionaryGetValue(displayDictionary, CFSTR("IODisplayLocation")));
        DCLCopyCString(ioLocation, info->ioLocation);
    }

    if (ioLocation.length == 0) {
        return;
    }

    io_service_t adapter = IORegistryEntryCopyFromPath(kIOMainPortDefault, (__bridge CFStringRef)ioLocation);
    if (adapter == MACH_PORT_NULL) {
        return;
    }

    CFTypeRef edid = DCLCopyRegistryProperty(adapter, "EDID UUID");
    DCLCopyCString(DCLStringFromCFType(edid), info->edidUUID);
    if (edid != NULL) {
        CFRelease(edid);
    }

    CFTypeRef attrs = DCLCopyRegistryProperty(adapter, "DisplayAttributes");
    if (attrs != NULL && CFGetTypeID(attrs) == CFDictionaryGetTypeID()) {
        NSDictionary *displayAttrs = (__bridge NSDictionary *)attrs;
        NSDictionary *productAttrs = displayAttrs[@"ProductAttributes"];
        if ([productAttrs isKindOfClass:NSDictionary.class]) {
            DCLCopyCString(productAttrs[@"ProductName"], info->displayName);
            DCLCopyCString(productAttrs[@"ManufacturerID"], info->manufacturer);
            DCLCopyCString(productAttrs[@"AlphanumericSerialNumber"], info->alphanumericSerial);
        }
    }
    if (attrs != NULL) {
        CFRelease(attrs);
    }

    IOObjectRelease(adapter);
}

int DCLCopyOnlineDisplays(DCLDisplayInfo *buffer, int capacity) {
    if (buffer == NULL || capacity <= 0) {
        return 0;
    }

    CGDirectDisplayID displays[DCL_MAX_DISPLAYS];
    CGDisplayCount displayCount = 0;
    CGError error = CGGetOnlineDisplayList((uint32_t)MIN(capacity, DCL_MAX_DISPLAYS), displays, &displayCount);
    if (error != kCGErrorSuccess) {
        return 0;
    }

    int count = (int)displayCount;
    for (int index = 0; index < count; index++) {
        DCLFillDisplayInfo(displays[index], &buffer[index]);
    }
    return count;
}

DCLStatus DCLSetDisplayEnabled(uint32_t runtimeDisplayID, bool enabled) {
    if (runtimeDisplayID == 0) {
        return DCLStatusInvalidArgument;
    }

    void *symbol = dlsym(RTLD_DEFAULT, "CGSConfigureDisplayEnabled");
    if (symbol == NULL) {
        return DCLStatusMissingPrivateAPI;
    }
    DCLCGSConfigureDisplayEnabledFn configureDisplayEnabled = (DCLCGSConfigureDisplayEnabledFn)symbol;

    CGDisplayConfigRef config = NULL;
    CGError error = CGBeginDisplayConfiguration(&config);
    if (error != kCGErrorSuccess || config == NULL) {
        return DCLStatusDisplayConfigFailed;
    }

    error = configureDisplayEnabled(config, (CGDirectDisplayID)runtimeDisplayID, enabled);
    if (error != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        return DCLStatusDisplayConfigFailed;
    }

    error = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    if (error != kCGErrorSuccess) {
        return DCLStatusDisplayConfigFailed;
    }

    return DCLStatusOK;
}

static DCLDDCPacket DCLCreateDDCPacket(uint8_t vcpCode) {
    DCLDDCPacket packet = {};
    packet.data[2] = vcpCode;
    packet.inputAddress = vcpCode == DCLAlternateInputVCP ? DCLAlternateInputAddress : DCLDefaultInputAddress;
    return packet;
}

static void DCLPrepareRead(uint8_t *data) {
    data[0] = 0x82;
    data[1] = 0x01;
    data[3] = 0x6e ^ data[0] ^ data[1] ^ data[2] ^ data[3];
}

static void DCLPrepareWrite(uint8_t *data, uint8_t value) {
    data[0] = 0x84;
    data[1] = 0x03;
    data[3] = value >> 8;
    data[4] = value & 255;
    data[5] = 0x6E ^ 0x51 ^ data[0] ^ data[1] ^ data[2] ^ data[3] ^ data[4];
}

static int DCLBytesUsed(uint8_t *data) {
    int bytes = 0;
    for (int index = 0; index < DCLDDCBufferSize; index++) {
        if (data[index] != 0) {
            bytes = index + 1;
        }
    }
    return bytes;
}

static IOReturn DCLPerformRead(IOAVServiceRef avService, DCLDDCPacket *packet) {
    memset(packet->data, 0, sizeof(uint8_t) * DCLDDCBufferSize);
    usleep(DCLDDCWaitMicroseconds);
    return IOAVServiceReadI2C(avService, 0x37, packet->inputAddress, packet->data, 12);
}

static IOReturn DCLPerformWrite(IOAVServiceRef avService, DCLDDCPacket *packet) {
    IOReturn result = kIOReturnSuccess;
    for (int index = 0; index < DCLDDCIterations; index++) {
        usleep(DCLDDCWaitMicroseconds);
        result = IOAVServiceWriteI2C(avService, 0x37, packet->inputAddress, packet->data, DCLBytesUsed(packet->data));
        if (result != kIOReturnSuccess) {
            return result;
        }
    }
    return result;
}

static DCLDDCValue DCLConvertI2CToDDC(uint8_t *bytes) {
    DCLDDCValue value = {};
    value.maxValue = bytes[7];
    value.currentValue = bytes[9];
    return value;
}

static kern_return_t DCLGetIORegistryRootIterator(io_iterator_t *iterator) {
    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    kern_return_t result = IORegistryEntryCreateIterator(root, kIOServicePlane, kIORegistryIterateRecursively, iterator);
    if (result != KERN_SUCCESS && *iterator != MACH_PORT_NULL) {
        IOObjectRelease(*iterator);
    }
    return result;
}

static IOAVServiceRef DCLCreateAVServiceForDisplay(DCLDisplayInfo display) {
    if (strlen(display.ioLocation) == 0) {
        return NULL;
    }

    io_iterator_t iterator = MACH_PORT_NULL;
    if (DCLGetIORegistryRootIterator(&iterator) != KERN_SUCCESS) {
        return NULL;
    }

    IOAVServiceRef avService = NULL;
    io_service_t service = MACH_PORT_NULL;
    CFStringRef externalLocation = CFSTR("External");

    while ((service = IOIteratorNext(iterator)) != MACH_PORT_NULL) {
        io_string_t servicePath;
        IORegistryEntryGetPath(service, kIOServicePlane, servicePath);
        bool matchesPath = strcmp(servicePath, display.ioLocation) == 0;
        IOObjectRelease(service);
        if (!matchesPath) {
            continue;
        }

        while ((service = IOIteratorNext(iterator)) != MACH_PORT_NULL) {
            io_name_t name;
            IORegistryEntryGetName(service, name);
            if (strcmp(name, "DCPAVServiceProxy") == 0) {
                CFTypeRef location = DCLCopyRegistryProperty(service, "Location");
                bool isExternal = location != NULL && CFGetTypeID(location) == CFStringGetTypeID() && CFStringCompare(location, externalLocation, 0) == kCFCompareEqualTo;
                if (location != NULL) {
                    CFRelease(location);
                }
                if (isExternal) {
                    avService = IOAVServiceCreateWithService(kCFAllocatorDefault, service);
                    IOObjectRelease(service);
                    break;
                }
            }
            IOObjectRelease(service);
        }
        break;
    }

    IOObjectRelease(iterator);
    return avService;
}

static bool DCLDisplayMatchesEDID(DCLDisplayInfo display, const char *edidUUID) {
    if (edidUUID == NULL || strlen(edidUUID) == 0) {
        return false;
    }
    return strcmp(display.edidUUID, edidUUID) == 0;
}

static bool DCLFindDisplayByEDID(const char *edidUUID, DCLDisplayInfo *outDisplay) {
    DCLDisplayInfo displays[DCL_MAX_DISPLAYS];
    int count = DCLCopyOnlineDisplays(displays, DCL_MAX_DISPLAYS);
    for (int index = 0; index < count; index++) {
        if (DCLDisplayMatchesEDID(displays[index], edidUUID)) {
            if (outDisplay != NULL) {
                *outDisplay = displays[index];
            }
            return true;
        }
    }
    return false;
}

DCLVCPReadResult DCLReadVCPByEDID(const char *edidUUID, uint8_t vcpCode) {
    DCLVCPReadResult result = { .status = DCLStatusInvalidArgument, .currentValue = -1, .maxValue = -1 };
    if (edidUUID == NULL || vcpCode == 0) {
        return result;
    }

    DCLDisplayInfo display = {};
    if (!DCLFindDisplayByEDID(edidUUID, &display)) {
        result.status = DCLStatusNoDisplay;
        return result;
    }

    IOAVServiceRef avService = DCLCreateAVServiceForDisplay(display);
    if (avService == NULL) {
        result.status = DCLStatusNoAVService;
        return result;
    }

    DCLDDCPacket packet = DCLCreateDDCPacket(vcpCode);
    DCLPrepareRead(packet.data);
    IOReturn writeResult = DCLPerformWrite(avService, &packet);
    if (writeResult != kIOReturnSuccess) {
        result.status = DCLStatusDDCWriteFailed;
        CFRelease(avService);
        return result;
    }

    DCLDDCPacket readPacket = {};
    readPacket.inputAddress = packet.inputAddress;
    IOReturn readResult = DCLPerformRead(avService, &readPacket);
    if (readResult != kIOReturnSuccess) {
        result.status = DCLStatusDDCReadFailed;
        CFRelease(avService);
        return result;
    }

    DCLDDCValue value = DCLConvertI2CToDDC(readPacket.data);
    result.status = DCLStatusOK;
    result.currentValue = value.currentValue;
    result.maxValue = value.maxValue;
    CFRelease(avService);
    return result;
}

DCLStatus DCLWriteVCPByEDID(const char *edidUUID, uint8_t vcpCode, uint8_t value) {
    if (edidUUID == NULL || vcpCode == 0) {
        return DCLStatusInvalidArgument;
    }

    DCLDisplayInfo display = {};
    if (!DCLFindDisplayByEDID(edidUUID, &display)) {
        return DCLStatusNoDisplay;
    }

    IOAVServiceRef avService = DCLCreateAVServiceForDisplay(display);
    if (avService == NULL) {
        return DCLStatusNoAVService;
    }

    DCLDDCPacket packet = DCLCreateDDCPacket(vcpCode);
    DCLPrepareWrite(packet.data, value);
    IOReturn writeResult = DCLPerformWrite(avService, &packet);
    CFRelease(avService);
    return writeResult == kIOReturnSuccess ? DCLStatusOK : DCLStatusDDCWriteFailed;
}

const char *DCLStatusDescription(DCLStatus status) {
    switch (status) {
        case DCLStatusOK:
            return "成功";
        case DCLStatusNoDisplay:
            return "没有匹配的显示器";
        case DCLStatusNoAVService:
            return "没有找到显示器 AV 服务";
        case DCLStatusDDCWriteFailed:
            return "DDC 写入失败";
        case DCLStatusDDCReadFailed:
            return "DDC 读取失败";
        case DCLStatusInvalidArgument:
            return "参数无效";
        case DCLStatusMissingPrivateAPI:
            return "系统缺少禁用显示器所需的私有接口";
        case DCLStatusDisplayConfigFailed:
            return "显示器配置事务失败";
    }
    return "未知状态";
}
