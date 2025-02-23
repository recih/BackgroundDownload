#include "PluginBase/AppDelegateListener.h"
#include <string>
#include "UserNotifications/UserNotifications.h"

typedef void (^UnityHandleEventsForBackgroundURLSession)();

static NSString* _Nonnull kUnityBackgroungDownloadSessionID = @"UnityBackgroundDownload";
static NSURLSession* gUnityBackgroundDownloadSession = nil;

static NSURLSession* UnityBackgroundDownloadSession();
static NSURL* GetDestinationUri(NSString* dest, NSFileManager** fileManager)
{
    NSFileManager* manager = [NSFileManager defaultManager];
    NSURL* documents = [[manager URLsForDirectory: NSDocumentDirectory inDomains: NSUserDomainMask] lastObject];
    NSURL* destUri = [documents URLByAppendingPathComponent: dest];
    if (fileManager != NULL)
        *fileManager = manager;
    return destUri;
}

static NSString* MakeNSString(const char16_t* str)
{
    return [NSString stringWithCharacters: (const unichar*)str length: std::char_traits<char16_t>::length(str)];
}

static int32_t NSStringToUTF16(NSString* str, void* buffer, unsigned size)
{
    NSUInteger ret;
    BOOL converted = [str getBytes:buffer maxLength:size usedLength:&ret encoding:NSUTF16StringEncoding options:NSStringEncodingConversionAllowLossy range:NSMakeRange(0, str.length) remainingRange:nil];
    return converted ? (int32_t)ret : 0;
}


static NSString* GetJPText(NSString* code) {
    if([code isEqualToString:@"CODE_1_DOWNLOADING_ITEM_TITLE"]) {
        return @"ARをダウンロードしています";
    }
    
    if([code isEqualToString:@"CODE_1_DOWNLOADING_MULTI_ITEMS_BODY"]) {
        return  @"%d件のダウンロードが進行中です";
    }
    
    if([code isEqualToString:@"CODE_1_DOWNLOADING_AN_ITEM_BODY"]) {
        return  @"1件のダウンロードが進行中です";
    }
    
    if([code isEqualToString:@"CODE_2_DOWNLOADING_COMPLETE_TITLE"]) {
        return @"ダウンロードが完了しました！";
    }
    
    if([code isEqualToString:@"CODE_2_DOWNLOADING_COMPLETE_BODY"]) {
        return @"全てのダウンロードが完了しました！";
    }
    
    return @"";
}

static NSString* GetENText(NSString* code) {
    if([code isEqualToString:@"CODE_1_DOWNLOADING_ITEM_TITLE"]) {
        return @"Now downloading...";
    }
    
    if([code isEqualToString:@"CODE_1_DOWNLOADING_MULTI_ITEMS_BODY"]) {
        return  @"Downloading %d items.";
    }
    
    if([code isEqualToString:@"CODE_1_DOWNLOADING_AN_ITEM_BODY"]) {
        return  @"Downloading an item.";
    }
    
    if([code isEqualToString:@"CODE_2_DOWNLOADING_COMPLETE_TITLE"]) {
        return @"Downloading complete!";
    }
    
    if([code isEqualToString:@"CODE_2_DOWNLOADING_COMPLETE_BODY"]) {
        return @"All of download tasks are completed.";
    }
    
    return @"";
}

static NSString* GetText(NSString* code) {
    if([NSLocale.preferredLanguages[0] hasPrefix:@"ja-"]) {
        return GetJPText(code);
    } else {
        return GetENText(code);
    }
}

enum
{
    kStatusDownloading = 0,
    kStatusDone = 1,
    kStatusFailed = 2,
};

@interface UnityBackgroundDownloadNotificationManager : NSObject
{
    UNMutableNotificationContent* content;
}
- (void)initialize: (NSString*)ntitle bodyText:(NSString*)nbody subtitleText:(NSString*)nsubtitle;
- (void)Post;
@end

@implementation UnityBackgroundDownloadNotificationManager
UNMutableNotificationContent* content;

- (void)initialize: (NSString*)ntitle bodyText:(NSString*)nbody subtitleText:(NSString*)nsubtitle{
    content = [[UNMutableNotificationContent alloc] init];
    content.title    = [NSString localizedUserNotificationStringForKey:ntitle arguments:nil];
    content.body     = [NSString localizedUserNotificationStringForKey:nbody arguments:nil];
    content.subtitle = [NSString localizedUserNotificationStringForKey:nsubtitle arguments:nil];
    content.sound    = [UNNotificationSound defaultSound];
}

- (void)Post {
    UNTimeIntervalNotificationTrigger* trigger = [UNTimeIntervalNotificationTrigger
                                                  triggerWithTimeInterval:5
                                                  repeats:NO];
    
    UNNotificationRequest* request = [UNNotificationRequest requestWithIdentifier:@"kslenz.notify.backgrounddownload" content:content trigger:trigger];
    UNUserNotificationCenter* center = [UNUserNotificationCenter currentNotificationCenter];

    [center addNotificationRequest:request
        withCompletionHandler:^(NSError * _Nullable error) {
        if (!error) {
            NSLog(@"notifer request sucess");
        }
    }];
}

@end

@interface UnityBackgroundDownload : NSObject
{
}

@property int status;
@property NSString* error;

@end

@implementation UnityBackgroundDownload
{
    int _status;
    NSString* _error;
}

@synthesize status = _status;
@synthesize error = _error;

- (id)init
{
    _status = kStatusDownloading;
    _error = nil;
    return self;
}

@end

@interface UnityBackgroundDownloadDelegate : NSObject<NSURLSessionDownloadDelegate>
{
}

@property (nullable) UnityHandleEventsForBackgroundURLSession finishEventsHandler;

+ (void)setFinishEventsHandler:(nonnull UnityHandleEventsForBackgroundURLSession)handler;

@end


@implementation UnityBackgroundDownloadDelegate
{
    NSMutableDictionary<NSURLSessionDownloadTask*, UnityBackgroundDownload*>* backgroundDownloads;
    UnityHandleEventsForBackgroundURLSession _finishEventsHandler;
}

@synthesize finishEventsHandler = _finishEventsHandler;

+ (void)setFinishEventsHandler:(nonnull UnityHandleEventsForBackgroundURLSession)handler
{
    NSURLSession* session = UnityBackgroundDownloadSession();
    UnityBackgroundDownloadDelegate* delegate = (UnityBackgroundDownloadDelegate*)session.delegate;
    delegate.finishEventsHandler = handler;
}

- (id)init
{
    backgroundDownloads = [[NSMutableDictionary<NSURLSessionDownloadTask*, UnityBackgroundDownload*> alloc] init];
    return self;
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location
{
    NSFileManager* fileManager;
    NSURL* destUri = GetDestinationUri(downloadTask.taskDescription, &fileManager);
    [fileManager replaceItemAtURL: destUri withItemAtURL: location backupItemName: nil options: NSFileManagerItemReplacementUsingNewMetadataOnly resultingItemURL: nil error: nil];
    UnityBackgroundDownload* download = [backgroundDownloads objectForKey: downloadTask];
   
    /* 通知処理 */
    UnityBackgroundDownloadDelegate* delegate = (UnityBackgroundDownloadDelegate*)session.delegate;
    UnityBackgroundDownloadNotificationManager* noticeManagaer = [[UnityBackgroundDownloadNotificationManager alloc] init];
    NSString* titleText = GetText(@"CODE_1_DOWNLOADING_ITEM_TITLE");
    NSString* bodyText;
    unsigned long nowTasksCount = [delegate taskCount] - 1;
    
    if(delegate == nil || nowTasksCount <= 0) {
        titleText = GetText(@"CODE_2_DOWNLOADING_COMPLETE_TITLE");
        bodyText = GetText(@"CODE_2_DOWNLOADING_COMPLETE_BODY");
    }
    else if(nowTasksCount == 1) {
        bodyText = GetText(@"CODE_1_DOWNLOADING_AN_ITEM_BODY");
    } else {
        bodyText = [NSString stringWithFormat:GetText(@"CODE_1_DOWNLOADING_MULTI_ITEMS_BODY"), nowTasksCount];
    }

    [noticeManagaer initialize:titleText bodyText:bodyText subtitleText:@""];
    [noticeManagaer Post];
    /* 通知処理ここまで */
    
    download.status = kStatusDone;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    if (error != nil)
    {
        UnityBackgroundDownload* download = [backgroundDownloads objectForKey: (NSURLSessionDownloadTask*)task];
        download.status = kStatusFailed;
        download.error = error.localizedDescription;
    }
}

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session
{
    if (self.finishEventsHandler != nil)
    {
        dispatch_async(dispatch_get_main_queue(), self.finishEventsHandler);
        self.finishEventsHandler = nil;
    }
}

- (NSURLSessionDownloadTask*)newSessionTask:(NSURLSession*)session withRequest:(NSURLRequest*)request forDestination:(NSString*)dest
{
    NSURLSessionDownloadTask *task = [session downloadTaskWithRequest: request];
    task.taskDescription = dest;
    UnityBackgroundDownload* download = [[UnityBackgroundDownload alloc] init];
    [backgroundDownloads setObject: download forKey: task];
    return task;
}

- (void)collectTasksForSession:(NSURLSession*)session
{
    [session getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> * _Nonnull dataTasks, NSArray<NSURLSessionUploadTask *> * _Nonnull uploadTasks, NSArray<NSURLSessionDownloadTask *> * _Nonnull downloadTasks) {
        for (NSUInteger i = 0; i < downloadTasks.count; ++i)
        {
            UnityBackgroundDownload* download = [[UnityBackgroundDownload alloc] init];
            [backgroundDownloads setObject: download forKey: downloadTasks[i]];
        }
    }];
}

- (NSUInteger)taskCount
{
    return backgroundDownloads.count;
}

- (void)getAllTasks:(void**)downloads
{
    NSEnumerator<NSURLSessionDownloadTask*>* tasks = backgroundDownloads.keyEnumerator;
    NSURLSessionDownloadTask* task = [tasks nextObject];
    int i = 0;
    while (task != nil)
    {
        downloads[i++] = (__bridge void*)task;
        task = [tasks nextObject];
    }
}

- (int)taskStatus:(NSURLSessionDownloadTask*)task
{
    UnityBackgroundDownload* download = [backgroundDownloads objectForKey:task];
    if (download == nil)
        return YES;
    return download.status;
}

- (NSString*)taskError:(NSURLSessionDownloadTask*)task
{
    UnityBackgroundDownload* download = [backgroundDownloads objectForKey:task];
    if (download != nil)
    {
        NSString* error = download.error;
        if (error != nil)
            return error;
    }
    return @"Unknown error";
}

- (void)removeTask:(NSURLSessionDownloadTask*)task
{
    [task cancel];
    [backgroundDownloads removeObjectForKey: task];
}

@end

static NSURLSession* UnityBackgroundDownloadSession()
{
    if (gUnityBackgroundDownloadSession == nil)
    {
        NSURLSessionConfiguration* config = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier: kUnityBackgroungDownloadSessionID];
        UnityBackgroundDownloadDelegate* delegate = [[UnityBackgroundDownloadDelegate alloc] init];
        gUnityBackgroundDownloadSession = [NSURLSession sessionWithConfiguration: config delegate: delegate delegateQueue: nil];

        [delegate collectTasksForSession: gUnityBackgroundDownloadSession];
    }

    return gUnityBackgroundDownloadSession;
}

@interface BackgroundDownloadAppListener : NSObject<AppDelegateListener>

@end

@implementation BackgroundDownloadAppListener

- (void)applicationWillFinishLaunchingWithOptions:(NSNotification*)notification
{
    UnityBackgroundDownloadSession();
}

- (void)onHandleEventsForBackgroundURLSession:(NSNotification *)notification
{
    NSDictionary* args = notification.userInfo;
    if (args != nil)
    {
        UnityHandleEventsForBackgroundURLSession handler = [args objectForKey:kUnityBackgroungDownloadSessionID];
        [UnityBackgroundDownloadDelegate setFinishEventsHandler: handler];
    }
}

@end

static BackgroundDownloadAppListener* s_AppEventListener;

class UnityBackgroundDownloadRegistrator
{
public:
    UnityBackgroundDownloadRegistrator()
    {
        s_AppEventListener = [[BackgroundDownloadAppListener alloc] init];
        UnityRegisterAppDelegateListener(s_AppEventListener);
    }
};

static UnityBackgroundDownloadRegistrator gRegistrator;

extern "C" void* UnityBackgroundDownloadCreateRequest(const char16_t* url)
{
    NSURL* downloadUrl = [NSURL URLWithString: MakeNSString(url)];
    NSMutableURLRequest* request = [[NSMutableURLRequest alloc] init];
    request.HTTPMethod = @"GET";
    request.URL = downloadUrl;
    return (__bridge_retained void*)request;
}

extern "C" void UnityBackgroundDownloadAddRequestHeader(void* req, const char16_t* header, const char16_t* value)
{
    NSMutableURLRequest* request = (__bridge NSMutableURLRequest*)req;
    [request setValue: MakeNSString(value) forHTTPHeaderField: MakeNSString(header)];
}

extern "C" void* UnityBackgroundDownloadStart(void* req, const char16_t* dest)
{
    NSMutableURLRequest* request = (__bridge_transfer NSMutableURLRequest*)req;
    NSString* destPath = MakeNSString(dest);
    NSURLSession* session = UnityBackgroundDownloadSession();
    UnityBackgroundDownloadDelegate* delegate = (UnityBackgroundDownloadDelegate*)session.delegate;
    
    /* 通知処理 */
    UnityBackgroundDownloadNotificationManager* noticeManagaer = [[UnityBackgroundDownloadNotificationManager alloc] init];
    NSString* bodyText;
    unsigned long taskCount = [delegate taskCount];
    
    if(taskCount == 0) {
        bodyText = GetText(@"CODE_1_DOWNLOADING_AN_ITEM_BODY");
    } else {
        bodyText = [NSString stringWithFormat:GetText(@"CODE_1_DOWNLOADING_MULTI_ITEMS_BODY"), taskCount + 1];
    }
    
    [noticeManagaer initialize:GetText(@"CODE_1_DOWNLOADING_ITEM_TITLE") bodyText:bodyText subtitleText:@""];
    [noticeManagaer Post];
    /* 通知処理ここまで */
    
    NSURLSessionDownloadTask *task = [delegate newSessionTask: session withRequest: request forDestination: destPath];
    [task resume];
    return (__bridge void*)task;
}

extern "C" int32_t UnityBackgroundDownloadGetCount()
{
    NSURLSession* session = UnityBackgroundDownloadSession();
    UnityBackgroundDownloadDelegate* delegate = (UnityBackgroundDownloadDelegate*)session.delegate;
    return (int32_t)[delegate taskCount];
}

extern "C" void UnityBackgroundDownloadGetAll(void** downloads)
{
    NSURLSession* session = UnityBackgroundDownloadSession();
    UnityBackgroundDownloadDelegate* delegate = (UnityBackgroundDownloadDelegate*)session.delegate;
    [delegate getAllTasks:downloads];
}

extern "C" int32_t UnityBackgroundDownloadGetUrl(void* download, char* buffer)
{
    NSURLSessionDownloadTask* task = (__bridge NSURLSessionDownloadTask*)download;
    NSString* url = task.originalRequest.URL.absoluteString;
    return NSStringToUTF16(url, buffer, 2048);
}

extern "C" int32_t UnityBackgroundDownloadGetFilePath(void* download, char* buffer)
{
    NSURLSessionDownloadTask* task = (__bridge NSURLSessionDownloadTask*)download;
    NSString* dest = task.taskDescription;
    return NSStringToUTF16(dest, buffer, 2048);
}

extern "C" int32_t UnityBackgroundDownloadGetStatus(void* download)
{
    NSURLSession* session = UnityBackgroundDownloadSession();
    UnityBackgroundDownloadDelegate* delegate = (UnityBackgroundDownloadDelegate*)session.delegate;
    NSURLSessionDownloadTask* task = (__bridge NSURLSessionDownloadTask*)download;
    return (int)[delegate taskStatus:task];
}

extern "C" float UnityBackgroundDownloadGetProgress(void* download)
{
    if (UnityBackgroundDownloadGetStatus(download) != kStatusDownloading)
        return 1.0f;
    if (UnityiOS111orNewer())
    {
        NSURLSessionDownloadTask* task = (__bridge NSURLSessionDownloadTask*)download;
        return (float)task.progress.fractionCompleted;
    }
    return -1.0f;
}

extern "C" int32_t UnityBackgroundDownloadGetError(void* download, void* buffer)
{
    NSURLSession* session = UnityBackgroundDownloadSession();
    UnityBackgroundDownloadDelegate* delegate = (UnityBackgroundDownloadDelegate*)session.delegate;
    NSURLSessionDownloadTask* task = (__bridge NSURLSessionDownloadTask*)download;
    NSString* error = [delegate taskError:task];
    return NSStringToUTF16(error, buffer, 2048);
}

extern "C" void UnityBackgroundDownloadDestroy(void* download)
{
    NSURLSessionDownloadTask* task = (__bridge NSURLSessionDownloadTask*)download;
    NSURLSession* session = UnityBackgroundDownloadSession();
    UnityBackgroundDownloadDelegate* delegate = (UnityBackgroundDownloadDelegate*)session.delegate;
    [delegate removeTask: task];
}

