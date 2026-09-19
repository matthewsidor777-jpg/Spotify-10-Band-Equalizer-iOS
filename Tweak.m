// SpotifyEQ10 - 10-band equalizer for Spotify
// Pure ObjC runtime swizzling

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define CUSTOM_BAND_COUNT 10

// ============================================
// MARK: - Helper to expand array to 10 values
// ============================================

static NSArray* expandTo10(NSArray *input) {
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:CUSTOM_BAND_COUNT];
    for (NSUInteger i = 0; i < CUSTOM_BAND_COUNT; i++) {
        if (input && i < input.count) {
            [result addObject:input[i]];
        } else {
            [result addObject:@(0.0)];
        }
    }
    return [result copy];
}

// ============================================
// MARK: - Direct ivar manipulation
// ============================================

static void expandArrayIvar(id model, const char *ivarName, int targetCount) {
    if (!model) return;
    
    Class cls = [model class];
    Ivar ivar = class_getInstanceVariable(cls, ivarName);
    
    if (ivar) {
        NSArray *currentArray = object_getIvar(model, ivar);
        NSLog(@"[SpotifyEQ10] Found %s ivar, current count: %lu", ivarName, (unsigned long)currentArray.count);
        
        if (currentArray && currentArray.count < targetCount) {
            NSMutableArray *expanded = [NSMutableArray arrayWithArray:currentArray];
            
            while (expanded.count < targetCount) {
                [expanded addObject:@(0.0)];
            }
            
            NSArray *newArray = [expanded copy];
            object_setIvar(model, ivar, newArray);
            NSLog(@"[SpotifyEQ10] Expanded %s to %lu elements", ivarName, (unsigned long)newArray.count);
        }
    } else {
        NSLog(@"[SpotifyEQ10] Ivar %s not found", ivarName);
    }
}

// ============================================
// MARK: - Original IMP storage  
// ============================================

static IMP orig_setValues = NULL;
static IMP orig_values = NULL;
static IMP orig_initWithLocalSettings = NULL;
static IMP orig_bands = NULL;

// ============================================
// MARK: - Replacement implementations
// ============================================

// SPTEqualizerModel setValues:
static void new_setValues(id self, SEL _cmd, NSArray *values) {
    NSLog(@"[SpotifyEQ10] setValues: input count=%lu", (unsigned long)values.count);

    // Let Spotify's original model process its native band count first.
    if (orig_setValues) {
        ((void(*)(id,SEL,NSArray*))orig_setValues)(self, _cmd, values);
    }

    // Replace the stored values with our 10-band values.
    NSArray *expanded = expandTo10(values);
    Ivar valuesIvar = class_getInstanceVariable([self class], "_values");
    if (valuesIvar) {
        object_setIvar(self, valuesIvar, expanded);
    }

    NSLog(@"[SpotifyEQ10] setValues: stored %lu bands", (unsigned long)expanded.count);

    // Ask Spotify's own audio engine to apply the current EQ state.
    SEL applySEL = NSSelectorFromString(@"applyEqualizer:");
    if ([self respondsToSelector:applySEL]) {
        NSLog(@"[SpotifyEQ10] Calling Spotify applyCoreEqualizer");
        ((void(*)(id,SEL,BOOL))objc_msgSend)(self, applySEL, YES);
    } else {
        NSLog(@"[SpotifyEQ10] applyCoreEqualizer not found");
    }
}

// SPTEqualizerModel values
static NSArray* new_values(id self, SEL _cmd) {
    Class cls = [self class];
    Ivar ivar = class_getInstanceVariable(cls, "_values");
    
    NSArray *result = nil;
    
    if (ivar) {
        result = object_getIvar(self, ivar);
    }
    
    if (!result && orig_values) {
        result = ((NSArray*(*)(id,SEL))orig_values)(self, _cmd);
    }
    
    // Расширяем если нужно
    if (!result || result.count < CUSTOM_BAND_COUNT) {
        result = expandTo10(result);
        if (ivar) {
            object_setIvar(self, ivar, result);
        }
    }
    
    NSLog(@"[SpotifyEQ10] values: returning %lu items", (unsigned long)result.count);
    return result;
}

// Стандартные частоты 10-полосного EQ
static NSArray* getStandardFrequencies(void) {
    return @[@(47), @(60), @(100), @(225), @(475), @(1200), @(2200), @(4000), @(8000), @(14000)];
}

static BOOL bandsDumped = NO;

// SPTEqualizerModel bands - _bands это массив NSNumber (частоты)
static NSArray* new_bands(id self, SEL _cmd) {
    Class cls = [self class];
    Ivar ivar = class_getInstanceVariable(cls, "_bands");

    NSArray *result = nil;

    if (ivar) {
        result = object_getIvar(self, ivar);
    }

    if (!result && orig_bands) {
        result = ((NSArray*(*)(id,SEL))orig_bands)(self, _cmd);
    }

    // Log Spotify's original band objects once.
    if (!bandsDumped && result.count > 0) {
        bandsDumped = YES;
        NSLog(@"[SpotifyEQ10] ========== ORIGINAL BANDS ==========");
        NSLog(@"[SpotifyEQ10] Class: %@", NSStringFromClass([result[0] class]));
        NSLog(@"[SpotifyEQ10] Count: %lu", (unsigned long)result.count);
        NSLog(@"[SpotifyEQ10] Values: %@", result);
        NSLog(@"[SpotifyEQ10] =====================================");
    }

    // IMPORTANT:
    // Keep Spotify's original _bands ivar untouched.
    // Return our 10 frequencies to the UI only.
    NSArray *frequencies = getStandardFrequencies();

    NSLog(@"[SpotifyEQ10] bands: returning 10 frequencies without replacing _bands");

    return frequencies;
}

// SPTEqualizerModel init methods
static id new_initWithLocalSettings(id self, SEL _cmd, id settings, id driver, id manager, id props, id prefs) {
    NSLog(@"[SpotifyEQ10] initWithLocalSettings called");
    
    id result = nil;
    if (orig_initWithLocalSettings) {
        result = ((id(*)(id,SEL,id,id,id,id,id))orig_initWithLocalSettings)(self, _cmd, settings, driver, manager, props, prefs);
    }
    
    if (result) {
        // Сразу после инициализации расширяем values и bands
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // Расширяем _values
            expandArrayIvar(result, "_values", CUSTOM_BAND_COUNT);
            
            // Принудительно вызываем bands() чтобы установить частоты
            if ([result respondsToSelector:@selector(bands)]) {
                NSLog(@"[SpotifyEQ10] Forcing bands() call");
                [result performSelector:@selector(bands)];
            }
        });
    }
    
    return result;
}

// ============================================
// MARK: - Hook installer
// ============================================

static void installHook(Class cls, SEL sel, IMP newImp, IMP *origImp) {
    if (!cls) return;
    
    Method method = class_getInstanceMethod(cls, sel);
    if (method) {
        *origImp = method_setImplementation(method, newImp);
        NSLog(@"[SpotifyEQ10] Hooked %@.%@", NSStringFromClass(cls), NSStringFromSelector(sel));
    } else {
        NSLog(@"[SpotifyEQ10] Method not found: %@.%@", NSStringFromClass(cls), NSStringFromSelector(sel));
    }
}

// ============================================
// MARK: - Constructor
// ============================================

static void installSpotifyEQHooks(void) {
    Class modelClass = NSClassFromString(@"SPTEqualizerModel");

    if (!modelClass) {
        NSLog(@"[SpotifyEQ10] SPTEqualizerModel not loaded yet; retrying...");
        return;
    }

    static BOOL installed = NO;
    if (installed) return;
    installed = YES;

    NSLog(@"[SpotifyEQ10] SPTEqualizerModel found! Installing hooks...");

    installHook(modelClass,
               NSSelectorFromString(@"setValues:"),
               (IMP)new_setValues,
               &orig_setValues);

    installHook(modelClass,
               NSSelectorFromString(@"values"),
               (IMP)new_values,
               &orig_values);

    installHook(modelClass,
               NSSelectorFromString(@"bands"),
               (IMP)new_bands,
               &orig_bands);

    installHook(modelClass,
               NSSelectorFromString(@"initWithLocalSettings:audioDriverController:connectManager:remoteConfigurationProperties:preferences:"),
               (IMP)new_initWithLocalSettings,
               &orig_initWithLocalSettings);

    NSLog(@"[SpotifyEQ10] Init complete!");
}

__attribute__((constructor))
static void init(void) {
    NSLog(@"[SpotifyEQ10] =====================================");
    NSLog(@"[SpotifyEQ10] Tweak loaded! Version 5.0");
    NSLog(@"[SpotifyEQ10] =====================================");

    installSpotifyEQHooks();

    if (!NSClassFromString(@"SPTEqualizerModel")) {
        dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);

        dispatch_async(queue, ^{
            for (int i = 0; i < 100; i++) {
                [NSThread sleepForTimeInterval:0.1];

                if (NSClassFromString(@"SPTEqualizerModel")) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        installSpotifyEQHooks();
                    });
                    break;
                }
            }
        });
    }
}

__attribute__((constructor))
static void inspectEqualizerMethods(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (int i = 0; i < 100; i++) {
            Class cls = NSClassFromString(@"SPTEqualizerModel");

            if (cls) {
                NSArray *selectors = @[
                    @"applyEqualizer:",
                    @"applyCoreEqualizer",
                    @"applyEqualizerToAudioUnit:",
                    @"applyEqualizerToDriver:"
                ];

                NSLog(@"[SpotifyEQ10] ===== METHOD SIGNATURES =====");

                for (NSString *name in selectors) {
                    SEL sel = NSSelectorFromString(name);
                    Method method = class_getInstanceMethod(cls, sel);

                    if (method) {
                        const char *types = method_getTypeEncoding(method);
                        NSLog(@"[SpotifyEQ10] %@ -> %s", name, types);
                    } else {
                        NSLog(@"[SpotifyEQ10] %@ -> NOT FOUND", name);
                    }
                }

                NSLog(@"[SpotifyEQ10] =============================");
                break;
            }

            [NSThread sleepForTimeInterval:0.1];
        }
    });
}

