// ============================================================================
// VSDumpHeaders.m - dylib riêng, nạp cùng tool, xuất HEADER của các class
// thuộc chính tool (đọc metadata qua Objective-C runtime, giống class-dump).
//
// - Chỉ đọc metadata, không đổi hành vi của app.
// - Chỉ lấy class nằm trong cùng image (file dylib) với dylib này.
// - BỎ các class xác thực: VSKeyAuth, VSIntegrity, VSResponseVerifier,
//   VSNetworkSecurity (và mọi class có tên chứa các từ này).
// - Kết quả: Documents/VSDump/<ClassName>.h và Documents/VSDump/_index.txt
//
// Build: thêm file này vào Makefile Theos như một tweak riêng (ví dụ
//        VSDumpHeaders_FILES = VSDumpHeaders.m), rồi inject cùng tool.
// Lấy file: Xcode -> Devices -> app -> Download Container, hoặc Filza/iMazing.
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static NSArray<NSString *> *VSDumpExcludeTokens(void) {
    return @[@"VSKeyAuth", @"VSIntegrity", @"VSResponseVerifier", @"VSNetworkSecurity"];
}

// Đổi type encoding của Objective-C thành kiểu C/ObjC đọc được (gần đúng).
static NSString *VSDumpTypeFromEncoding(const char *enc) {
    if (!enc || !*enc) return @"id";
    switch (enc[0]) {
        case 'v': return @"void";
        case 'B': return @"BOOL";
        case 'c': return @"char";
        case 'C': return @"unsigned char";
        case 's': return @"short";
        case 'S': return @"unsigned short";
        case 'i': return @"int";
        case 'I': return @"unsigned int";
        case 'l': return @"long";
        case 'L': return @"unsigned long";
        case 'q': return @"long long";
        case 'Q': return @"unsigned long long";
        case 'f': return @"float";
        case 'd': return @"double";
        case '*': return @"char *";
        case ':': return @"SEL";
        case '#': return @"Class";
        case '@': {
            if (enc[1] == '"') {                       // @"ClassName"
                const char *start = enc + 2;
                const char *end = strchr(start, '"');
                if (end) {
                    NSString *cls = [[NSString alloc] initWithBytes:start length:(end - start) encoding:NSUTF8StringEncoding];
                    return [cls stringByAppendingString:@" *"];
                }
            }
            return @"id";
        }
        case '^': return @"void *";
        case '{': return @"struct";
        default:  return @"id";
    }
}

static NSString *VSDumpSafeName(NSString *s) {
    NSCharacterSet *ok = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        [out appendString:[ok characterIsMember:c] ? [NSString stringWithCharacters:&c length:1] : @"_"];
    }
    return out.length ? out : @"unnamed";
}

static BOOL VSDumpIsExcluded(NSString *name) {
    for (NSString *t in VSDumpExcludeTokens()) {
        if ([name rangeOfString:t].location != NSNotFound) return YES;
    }
    return NO;
}

static NSString *VSDumpOwnImagePath(void) {
    Dl_info info;
    if (dladdr((const void *)&VSDumpOwnImagePath, &info) && info.dli_fname) {
        return [NSString stringWithUTF8String:info.dli_fname];
    }
    return nil;
}

static NSString *VSDumpMethodLine(Method m, BOOL isClassMethod) {
    NSString *ret = VSDumpTypeFromEncoding(method_copyReturnType(m) ? method_copyReturnType(m) : "v");
    SEL sel = method_getName(m);
    NSString *selName = NSStringFromSelector(sel);
    unsigned int argc = method_getNumberOfArguments(m);
    NSArray *parts = [selName componentsSeparatedByString:@":"];   // kể cả phần rỗng cuối
    NSMutableString *line = [NSMutableString stringWithFormat:@"%@ (%@)", isClassMethod ? @"+" : @"-", ret];
    if (argc <= 2) {
        [line appendString:selName];
    } else {
        NSUInteger k = 0;
        for (unsigned int i = 2; i < argc; i++, k++) {
            char *argEnc = method_copyArgumentType(m, i);
            NSString *argT = VSDumpTypeFromEncoding(argEnc ? argEnc : "@");
            if (argEnc) free(argEnc);
            NSString *key = (k < parts.count) ? parts[k] : [NSString stringWithFormat:@"arg%u", i];
            if (i > 2) [line appendString:[NSString stringWithFormat:@" %@", key]];
            else [line appendString:key];
            [line appendFormat:@":(%@)a%u", argT, i - 2];
        }
    }
    [line appendString:@";"];
    return line;
}

static void VSDumpClass(Class cls, NSString *dir, NSMutableString *index) {
    NSString *name = NSStringFromClass(cls);
    NSMutableString *h = [NSMutableString string];
    [h appendFormat:@"// Header khôi phục từ runtime: %@\n", name];
    [h appendString:@"#import <Foundation/Foundation.h>\n#import <UIKit/UIKit.h>\n\n"];

    Class superCls = class_getSuperclass(cls);
    [h appendFormat:@"@interface %@ : %@\n", name, superCls ? NSStringFromClass(superCls) : @"NSObject"];

    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList(cls, &ivarCount);
    if (ivarCount) {
        [h appendString:@"{\n"];
        for (unsigned int i = 0; i < ivarCount; i++) {
            const char *n = ivar_getName(ivars[i]);
            NSString *t = VSDumpTypeFromEncoding(ivar_getTypeEncoding(ivars[i]));
            [h appendFormat:@"    %@ %s;\n", t, n ? n : "_unnamed"];
        }
        [h appendString:@"}\n"];
    }
    if (ivars) free(ivars);

    unsigned int propCount = 0;
    objc_property_t *props = class_copyPropertyList(cls, &propCount);
    for (unsigned int i = 0; i < propCount; i++) {
        const char *pname = property_getName(props[i]);
        const char *attrs = property_getAttributes(props[i]);
        NSString *attrStr = [NSString stringWithUTF8String:attrs ?: ""];
        NSString *typeEnc = @"id";
        NSArray *fields = [attrStr componentsSeparatedByString:@","];
        if (fields.count && [fields[0] hasPrefix:@"T"]) {
            typeEnc = [fields[0] substringFromIndex:1];
        }
        NSString *t = VSDumpTypeFromEncoding([typeEnc UTF8String]);
        [h appendFormat:@"@property (nonatomic) %@ %s;\n", t, pname ?: "unnamed"];
    }
    if (props) free(props);

    unsigned int imCount = 0;
    Method *ims = class_copyMethodList(cls, &imCount);
    for (unsigned int i = 0; i < imCount; i++) {
        [h appendFormat:@"%@\n", VSDumpMethodLine(ims[i], NO)];
    }
    if (ims) free(ims);

    Class meta = object_getClass(cls);
    unsigned int cmCount = 0;
    Method *cms = class_copyMethodList(meta, &cmCount);
    for (unsigned int i = 0; i < cmCount; i++) {
        [h appendFormat:@"%@\n", VSDumpMethodLine(cms[i], YES)];
    }
    if (cms) free(cms);

    [h appendString:@"@end\n"];

    NSString *file = [dir stringByAppendingPathComponent:[VSDumpSafeName(name) stringByAppendingString:@".h"]];
    [h writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [index appendFormat:@"%@  (ivar %u, property %u, method %u + %u)\n",
        name, ivarCount, propCount, imCount, cmCount];
}

static void VSDumpRun(void) {
    NSString *own = VSDumpOwnImagePath();
    NSString *ownBase = own ? [own lastPathComponent] : nil;

    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = [[docs firstObject] stringByAppendingPathComponent:@"VSDump"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    unsigned int total = 0;
    Class *classes = objc_copyClassList(&total);
    NSMutableString *index = [NSMutableString stringWithFormat:@"Dump của image: %@\n\n", ownBase ?: @"?"];
    int count = 0, skipped = 0;

    for (unsigned int i = 0; i < total; i++) {
        Class cls = classes[i];
        const char *img = class_getImageName(cls);
        if (!img || !ownBase) continue;
        if (![[NSString stringWithUTF8String:img] hasSuffix:ownBase]) continue;

        NSString *name = NSStringFromClass(cls);
        if (VSDumpIsExcluded(name)) { skipped++; continue; }

        VSDumpClass(cls, dir, index);
        count++;
    }
    free(classes);

    [index appendFormat:@"\nĐã xuất: %d class, bỏ qua (xác thực): %d\n", count, skipped];
    [index writeToFile:[dir stringByAppendingPathComponent:@"_index.txt"] atomically:YES
              encoding:NSUTF8StringEncoding error:nil];
}

__attribute__((constructor)) static void VSDumpHeadersInit(void) {
    // Đợi app và tool khởi tạo xong rồi mới đọc class.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        VSDumpRun();
    });
}
