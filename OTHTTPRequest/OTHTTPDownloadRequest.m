//
//  OTHTTPDownloadRequest.m
//  DownloadTest
//
//  Created by openthread on 12/17/12.
//  Copyright (c) 2012 openthread. All rights reserved.
//

#import "OTHTTPDownloadRequest.h"
#import "OTLivingRequestContainer.h"

#if !__has_feature(objc_arc)
#error ARC is required
#endif

@interface OTHTTPDownloadRequest ()
@property (nonatomic, strong) NSURLConnection *connection;
@property (nonatomic, copy) void(^successedCallback)(OTHTTPDownloadRequest *request);
@property (nonatomic, copy) void(^failedCallback)(OTHTTPDownloadRequest *request, NSError *error);
@property (nonatomic, copy) void(^writeFileFailedCallback)(OTHTTPDownloadRequest *request, NSException *exception);
@end

@implementation OTHTTPDownloadRequest
{
    NSMutableURLRequest *_request;
    NSFileHandle *_cacheFileHandle;

    NSString *_urlString; //download URL
    NSString *_cacheFilePath; //cache file path
    NSString *_finishedFilePath; //finished file path

    NSUInteger _responseStatusCode; //HTTP Status Code
    NSString *_responseMIMEType;
    long long _currentContentLength; //current downloaded bytes count
    long long _expectedContentLength; //expected file length

    //Calc current download speed
    NSTimeInterval _connectionBeginTime;
    long long _dataLengthAddedSinceConnectionBegin;
    double _averageDownloadSpeed;
    NSTimeInterval _lastProgressCallbackTime;

    NSUInteger _currentRetriedTimes;
}
@synthesize connection = _connection;

#pragma mark - Properties

- (NSUInteger)responseStatusCode
{
    return _responseStatusCode;
}

- (NSString *)responseMIMEType
{
    return _responseMIMEType;
}

- (NSString *)cacheFilePath
{
    return _cacheFilePath;
}

- (NSString *)finishedFilePath
{
    return _finishedFilePath;
}

- (BOOL)isDownloading
{
    return self.connection != nil;
}

- (NSString *)requestURL
{
    return _urlString;
}

- (long long)downloadedFileSize
{
    return _currentContentLength;
}

- (long long)expectedFileSize
{
    return _expectedContentLength;
}

- (NSTimeInterval)timeoutInterval
{
    return _request.timeoutInterval;
}

- (void)setTimeoutInterval:(NSTimeInterval)timeoutInterval
{
    _request.timeoutInterval = timeoutInterval;
}

#pragma mark - Set callback blocks

- (void)setSuccessedCallback:(void (^)(OTHTTPDownloadRequest *))successedCallback
              failedCallback:(void (^)(OTHTTPDownloadRequest *, NSError *))failedCallback
     writeFileFailedCallback:(void (^)(OTHTTPDownloadRequest *, NSException *))writeFileFailedCallback
{
    self.successedCallback = successedCallback;
    self.failedCallback = failedCallback;
    self.writeFileFailedCallback = writeFileFailedCallback;
}

#pragma mark - Life cycle

- (id)initWithURL:(NSString *)urlString
        cacheFile:(NSString *)cacheFile
 finishedFilePath:(NSString *)finishedFilePath
{
    self = [super init];
    if (self)
    {
        //Set cache file path and finished file path
        _urlString = urlString;
        
        //Some Japanese string like べ may have differen length before convert to NSURL then convert back to path.
        //Before convert then convert back, べ 's length is 1, after that, its length is 2.
        //Which may lead to compare path string and converted path string returns the two string are different.
        //Convert it at the first time here, to avoid the later different.
        NSURL *cacheURL = [NSURL fileURLWithPath:cacheFile];
        _cacheFilePath = cacheURL.path;
        NSURL *finishedURL = [NSURL fileURLWithPath:finishedFilePath];
        _finishedFilePath = finishedURL.path;
        
        NSURL *url = [NSURL URLWithString:_urlString];
        _request = [[NSMutableURLRequest alloc] initWithURL:url
                                                cachePolicy:NSURLRequestReloadIgnoringCacheData
                                            timeoutInterval:15];
        
        self.isLowPriority = YES;
        self.downloadProgressCallbackInterval = 0.2;
        self.retryAfterFailedDuration = 0.5f;
        self.retryTimes = 1;
        _currentRetriedTimes = 0;
    }
    return self;
}

- (void)dealloc
{
    [self pause];
}

#pragma mark - Manage connection methods

- (void)beginConnection
{
    [OTHTTPDownloadRequest createFileAtPath:_cacheFilePath];
    _cacheFileHandle = [NSFileHandle fileHandleForUpdatingAtPath:_cacheFilePath];
    if (_cacheFileHandle)
    {
        [_cacheFileHandle seekToEndOfFile];

        _responseStatusCode = NSNotFound;

        _connectionBeginTime = [[NSDate date] timeIntervalSince1970];
        _lastProgressCallbackTime = _connectionBeginTime;
        _dataLengthAddedSinceConnectionBegin = 0;
        _averageDownloadSpeed = 0;

        //get last download data size
        long long dataSize = [OTHTTPDownloadRequest fileSizeAtPath:_cacheFilePath];
        _currentContentLength = dataSize;

        //set request range
        NSString *rangeString = [NSString stringWithFormat:@"bytes=%lld-", dataSize];
        [_request setValue:rangeString forHTTPHeaderField:@"Range"];

        //Setup connection
        self.connection = [[NSURLConnection alloc] initWithRequest:_request delegate:self startImmediately:NO];
        if (!self.isLowPriority)
        {
            [self.connection scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        }
        [self.connection start];
        [[OTLivingRequestContainer sharedContainer] addRequest:self];
    }
    else
    {
        NSException *exception = [[NSException alloc] initWithName:@"OTHTTPDownloadRequest write failed"
                                                            reason:@"Failed create file handle at start."
                                                          userInfo:@{ @"CachePath" : _cacheFilePath }];
        if ([self.delegate respondsToSelector:@selector(downloadRequestWriteFileFailed:exception:)])
        {
            [self.delegate downloadRequestWriteFileFailed:self exception:exception];
        }
        if (self.writeFileFailedCallback)
        {
            self.writeFileFailedCallback(self, exception);
        }
    }
}

- (void)closeConnection
{
    if (self.connection)
    {
        [self.connection cancel];
        self.connection = nil;
        _responseStatusCode = NSNotFound;
        _responseMIMEType = nil;
    }
    if (_cacheFileHandle)
    {
        [_cacheFileHandle closeFile];
        _cacheFileHandle = nil;
    }
    
    //self may dealloc after remove from container, so don't execute any code below this line
    [[OTLivingRequestContainer sharedContainer] removeRequest:self];
}

- (void)start
{
    if (![NSThread isMainThread])
    {
        [self performSelectorOnMainThread:@selector(start) withObject:nil waitUntilDone:NO];
        return;
    }
    if (!self.connection)
    {
        _currentRetriedTimes = 0;
        [self beginConnection];
    }
}

- (void)pause
{
    [self closeConnection];
}

#pragma mark - Handle HTTP headers

- (void)addCookies:(NSArray <NSHTTPCookie *> *)cookies
{
    if ([cookies count] > 0)
    {
        NSHTTPCookie *cookie;
        NSString *cookieHeader = nil;
        for (cookie in cookies)
        {
            if (!cookieHeader)
            {
                cookieHeader = [NSString stringWithFormat:@"%@=%@", [cookie name], [cookie value]];
            }
            else
            {
                cookieHeader = [NSString stringWithFormat:@"%@; %@=%@", cookieHeader, [cookie name], [cookie value]];
            }
        }
        if (cookieHeader)
        {
            [_request setValue:cookieHeader forHTTPHeaderField:@"Cookie"];
        }
    }
}

- (void)setCookies:(NSArray <NSHTTPCookie *> *)cookies
{
    [self addCookies:cookies];
}

- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field
{
    [_request addValue:value forHTTPHeaderField:field];
}

#pragma mark - Write stream

//Write data to file.
//If write failed (due to disk full, etc.), download request will be automatically pause
- (BOOL)writeToFile:(NSData *)data
{
    BOOL writeSuccessed = YES;
    NSFileHandle *writeFileHandle = _cacheFileHandle;
    if (writeFileHandle != nil)
    {
        @try
        {
            [writeFileHandle writeData:data];
        }
        @catch (NSException *exception)
        {
            //Write successed callback. pause self later
            writeSuccessed = NO;
            if ([self.delegate respondsToSelector:@selector(downloadRequestWriteFileFailed:exception:)])
            {
                [self.delegate downloadRequestWriteFileFailed:self exception:exception];
            }
            if (self.writeFileFailedCallback)
            {
                self.writeFileFailedCallback(self, exception);
            }
        }
    }
    else
    {
        writeSuccessed = NO;
    }
    if (!writeSuccessed) //If write failed, pause self.
    {
        [self pause];
    }
    return writeSuccessed;
}

#pragma mark - URLConnection callback

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    _responseStatusCode = [(NSHTTPURLResponse *)response statusCode]; //status code为406可能是range超范围了
    _responseMIMEType = [(NSHTTPURLResponse *)response MIMEType];
    if (200 == _responseStatusCode) //request uncached file
    {
        long long expectedLengthInCurrentRequest = [response expectedContentLength];
        _expectedContentLength = expectedLengthInCurrentRequest;
    }
    else if (206 == _responseStatusCode) //resume broken file downloading
    {
        long long expectedLengthInCurrentRequest = [response expectedContentLength];
        _expectedContentLength = _currentContentLength + expectedLengthInCurrentRequest;
    }
    if ([self.delegate respondsToSelector:@selector(downloadRequestReceivedResponse:)])
    {
        [self.delegate downloadRequestReceivedResponse:self];
    }
    if (self.receivedResponseCallback)
    {
        self.receivedResponseCallback(self);
    }
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    if (200 == _responseStatusCode || 206 == _responseStatusCode)
    {
        if (![self writeToFile:data])
        {
            [self closeConnection];
            NSError *error = [[NSError alloc] initWithDomain:@"OTHTTPDownloadRequest failed write data to local file"
                                                        code:-1000
                                                    userInfo:nil];
            [self failedCallbackWithError:error];
            return;
        }
        NSUInteger dataLength = [data length];
        _currentContentLength += dataLength;

        //Calculate current download speed
        NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
        _dataLengthAddedSinceConnectionBegin += dataLength;
        NSTimeInterval elapsed = currentTime - _connectionBeginTime;
        _averageDownloadSpeed = (elapsed == 0 ? 0 : _dataLengthAddedSinceConnectionBegin / elapsed);

        //Callback delegate
        if (currentTime - _lastProgressCallbackTime > self.downloadProgressCallbackInterval)
        {
            _lastProgressCallbackTime = currentTime;
            double progress = 0.0f;
            if (_expectedContentLength != 0)
            {
                progress = (double)(_currentContentLength / (double)_expectedContentLength);
            }
            if ([self.delegate respondsToSelector:@selector(downloadRequest:currentProgressUpdated:speed:totalReceived:expectedDataSize:)])
            {
                [self.delegate downloadRequest:self
                        currentProgressUpdated:progress
                                         speed:_averageDownloadSpeed
                                 totalReceived:_currentContentLength
                              expectedDataSize:_expectedContentLength];
            }
            if (self.progressUpdatedCallback)
            {
                self.progressUpdatedCallback(self, progress, _averageDownloadSpeed, _currentContentLength, _expectedContentLength);
            }
        }
    }
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    NSUInteger responseCode = _responseStatusCode;
    [self closeConnection];
    if (200 == responseCode || 206 == responseCode || 416 == responseCode) //Response code right
    {
        if ((_currentContentLength == 0) || //Nothing downloaded
            ((_currentContentLength != _expectedContentLength) && _expectedContentLength != -1)) //Response data length error
        {
            NSError *error = [[NSError alloc] initWithDomain:@"OTHTTPDownloadRequest response data length error"
                                                        code:responseCode
                                                    userInfo:nil];
            [self failedCallbackWithError:error];
            [[NSFileManager defaultManager] removeItemAtPath:_cacheFilePath error:nil];
        }
        else //Response data length right
        {
            NSError *error;
            //remove old file
            if ([[NSFileManager defaultManager] fileExistsAtPath:_finishedFilePath])
            {
                [[NSFileManager defaultManager] removeItemAtPath:_finishedFilePath error:&error];
            }
            //move file
            BOOL moveSuccessed = [[NSFileManager defaultManager] moveItemAtPath:_cacheFilePath
                                                                         toPath:_finishedFilePath
                                                                          error:&error];
            if (moveSuccessed) //Move successed
            {
                if ([self.delegate respondsToSelector:@selector(downloadRequestFinished:)])
                {
                    [self.delegate downloadRequestFinished:self];
                }
                if (self.successedCallback)
                {
                    self.successedCallback(self);
                }
            }
            else //Move failed
            {
                NSException *exception = [[NSException alloc] initWithName:@"OTHTTPDownloadRequest write failed"
                                                                    reason:@"Move cached file to finished file failed."
                                                                  userInfo:@{ @"CachePath" : _cacheFilePath,
                                                                              @"FinishedPath" : _finishedFilePath }];
                if ([self.delegate respondsToSelector:@selector(downloadRequestWriteFileFailed:exception:)])
                {
                    [self.delegate downloadRequestWriteFileFailed:self exception:exception];
                }
                if (self.writeFileFailedCallback)
                {
                    self.writeFileFailedCallback(self, exception);
                }
            }
        }
    }
    else //Response code error
    {
        NSError *error = [[NSError alloc] initWithDomain:@"OTHTTPDownloadRequest response code error"
                                                    code:responseCode
                                                userInfo:nil];
        [self failedCallbackWithError:error];
    }
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    [self closeConnection];
    [self failedCallbackWithError:error];
}

#pragma mark - Callback

- (void)failedCallbackWithError:(NSError *)error
{
    if (_currentRetriedTimes < self.retryTimes)
    {
        _currentRetriedTimes++;
        [self performSelector:@selector(beginConnection) withObject:nil afterDelay:self.retryAfterFailedDuration];
        return;
    }

    if ([self.delegate respondsToSelector:@selector(downloadRequestFailed:error:)])
    {
        [self.delegate downloadRequestFailed:self error:error];
    }
    if (self.failedCallback)
    {
        self.failedCallback(self, error);
    }
}

#pragma mark - Class helpers

//Returns YES if create successed or file already exists
+ (BOOL)createFileAtPath:(NSString *)fileFullPath
{
    if ([[NSFileManager defaultManager] fileExistsAtPath:fileFullPath] == NO)
    {
        NSError *error = nil;
        NSString *folderPath = [fileFullPath stringByDeletingLastPathComponent];
        BOOL createFolderSuccessed = [[NSFileManager defaultManager] createDirectoryAtPath:folderPath
                                                               withIntermediateDirectories:YES
                                                                                attributes:nil
                                                                                     error:&error];
        if (!createFolderSuccessed)
        {
            return NO;
        }
        
        BOOL createSuccessed = [[NSFileManager defaultManager] createFileAtPath:fileFullPath
                                                                       contents:nil
                                                                     attributes:nil];
        return createSuccessed;
    }
    return YES;
}

+ (long long)fileSizeAtPath:(NSString *)fileFullPath
{
    NSFileManager *manager = [NSFileManager defaultManager];
    if ([manager fileExistsAtPath:fileFullPath])
    {
        return [[manager attributesOfItemAtPath:fileFullPath error:nil] fileSize];
    }
    return 0;
}

@end
