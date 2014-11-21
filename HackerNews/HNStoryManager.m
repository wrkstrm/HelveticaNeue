//
//  HNStoryManager.m
//  HackerNews
//
//  Created by Cristian Monterroza on 11/19/14.
//  Copyright (c) 2014 wrkstrm. All rights reserved.
//

#import "HNStoryManager.h"
#import "HNUser.h"
#import "HNFavicon.h"
#import "NSCache+WSMUtilities.h"


@interface HNStoryManager ()

@property (nonatomic, strong) AFHTTPRequestOperationManager *httpManager;
@property (nonatomic, strong) Firebase *hackerAPI;
@property (nonatomic, strong) Firebase *topStoriesAPI;
@property (nonatomic, strong) Firebase *itemsAPI;

@property (nonatomic, strong) NSMutableDictionary *firebaseSignalDictionary;

@property (nonatomic, strong, readwrite) NSCache *faviconCache;
@property (nonatomic, strong) CBLDatabase *newsDatabase;
@property (nonatomic, strong) CBLDocument *topStoriesDocument;

@property (nonatomic, strong, readwrite) NSArray *currentTopStories;

//Placeholder Imagee
@property (nonatomic, strong) UIImage *webImagePlaceholderData;

@end

@implementation HNStoryManager

WSM_SINGLETON_WITH_NAME(sharedInstance)

#define topStoriesDocID @"topstories"
#define webPlaceHolderName @"web_black"

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _currentUser = [HNUser defaultUser] ?:
    [HNUser createDefaultUserWithProperties:@{@"hiddenStories":@[],
                                              @"minimumScore":@0}];
    _newsDatabase = [_currentUser userDatabase];
    _newsDatabase.maxRevTreeDepth = 1;
    NSError *error;
    [_newsDatabase compact:&error];
    WSMLog(error, @"Error compacting database: %@", error);
    _topStoriesDocument = [_newsDatabase existingDocumentWithID:topStoriesDocID];
    WSM_LAZY(_topStoriesDocument, ({
        CBLDocument *doc = [_newsDatabase documentWithID:topStoriesDocID];
        NSError *error;
        [doc mergeUserProperties:@{@"stories":@[]} error:&error];
        WSMLog(error, @"ERROR: No topstories document - %@", error);
        doc;
    }));
    
    _firebaseSignalDictionary = @{}.mutableCopy;
    
    _faviconCache = NSCache.new;
    _faviconCache[webPlaceHolderName] = [UIImage imageNamed:webPlaceHolderName];
    NSAssert(_faviconCache[webPlaceHolderName],@"Must be true");
    
    _httpManager = [AFHTTPRequestOperationManager manager];
    _httpManager.operationQueue.maxConcurrentOperationCount = 1;
    _httpManager.operationQueue.qualityOfService = NSQualityOfServiceUserInteractive;
    
    _hackerAPI = [[Firebase alloc] initWithUrl:@"https://hacker-news.firebaseio.com/v0/"];
    _topStoriesAPI = [_hackerAPI childByAppendingPath:@"topstories"];
    _itemsAPI = [_hackerAPI childByAppendingPath:@"item"];
    
    //    self.currentTopStories = @[];
    self.currentTopStories = self.topStoriesWithCurrentFilters;
    @weakify(self);
    [_topStoriesAPI observeEventType:FEventTypeValue withBlock:^(FDataSnapshot *snapshot) {
        @strongify(self);
        if (snapshot.value) {
            [_topStoriesDocument mergeUserProperties:@{@"stories":snapshot.value} error: nil];
            NSLog(@"Updating topStories!");
            self.currentTopStories = self.topStoriesWithCurrentFilters;
        }
    }];
    
    [self manageNewObservations];
    [self manageOldObservations];
    return self;
}

- (void)setSortStyle:(HNSortStyle)sortStyle {
    if (_sortStyle != sortStyle) {
        _sortStyle = sortStyle;
        self.currentTopStories = [self topStoriesWithCurrentFilters];
    }
}

- (void)manageNewObservations {
    [[RACObserve(self, currentTopStories)
      combinePreviousWithStart:@[]
      reduce:^id(NSArray *old, NSArray *new) {
          return [[new.rac_sequence filter:^BOOL(NSNumber *value) {
              return ![old containsObject:value];
          }] array];
      }] subscribeNext:^(NSArray *newStories) {
          NSLog(@"NewStories Count: %lu",newStories.count);
          for (NSNumber *number in newStories) {
              [self firebaseSignalForItemNumber:number];
          }
      }];
}

- (void)manageOldObservations {
    [[RACObserve(self, currentTopStories)
      combinePreviousWithStart:@[]
      reduce:^id(NSArray *old, NSArray *new) {
          return [[old.rac_sequence filter:^BOOL(NSNumber *value) {
              return ![new containsObject:value];
          }] array];
      }] subscribeNext:^(NSArray *oldStories) {
          NSNull *null = [NSNull null];
          NSMutableArray *staleObservations = [[self.firebaseSignalDictionary
                                                objectsForKeys:oldStories
                                                notFoundMarker:null] mutableCopy];
          [staleObservations removeObject:null];
          for (NSNumber *number in oldStories) {
              [self discardObservationsForItem:number];
              [[self.newsDatabase documentWithID:number.stringValue] purgeDocument:nil];
          }
      }];
}

- (void)discardObservationsForItem:(NSNumber *)number {
    RACSubject *subject = self.firebaseSignalDictionary[number];
    [subject sendCompleted];
    [self.firebaseSignalDictionary removeObjectForKey:number];
}

- (NSArray *)topStoriesWithCurrentFilters {
    NSArray *sortedArray;
    switch (self.sortStyle) {
        case kHNSortStylePoints: {
            sortedArray = [self.topStoriesDocument[@"stories"] sortedArrayUsingComparator:
                           ^NSComparisonResult(NSNumber *obj1, NSNumber *obj2) {
                               CBLDocument *doc1 = [self documentForItemNumber:obj1];
                               CBLDocument *doc2 = [self documentForItemNumber:obj2];
                               NSInteger score1 = [doc1[@"score"] integerValue];
                               NSInteger score2 = [doc2[@"score"] integerValue];
                               WSM_COMPARATOR(score1 > score2);
                           }];
        } break;
        case kHNSortStyleComments: {
            sortedArray = [self.topStoriesDocument[@"stories"] sortedArrayUsingComparator:
                           ^NSComparisonResult(NSNumber *obj1, NSNumber *obj2) {
                               CBLDocument *doc1 = [self documentForItemNumber:obj1];
                               CBLDocument *doc2 = [self documentForItemNumber:obj2];
                               NSInteger comments1 = [doc1[@"kids"] count];
                               NSInteger comments2 = [doc2[@"kids"] count];
                               WSM_COMPARATOR(comments1 > comments2);
                           }];
        } break;
        default: sortedArray = [self.topStoriesDocument[@"stories"] mutableCopy]; break;
    }
    return [sortedArray filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^
             BOOL(NSNumber *storyNumber, NSDictionary *bindings) {
                 CBLDocument *doc1 = [self documentForItemNumber:storyNumber];
                 NSInteger score1 = [doc1[@"score"] integerValue];
                 return ![self.currentUser.hiddenStories containsObject:storyNumber]
                 || !(self.currentUser.minimumScore <=  score1);
             }]];
    
}

- (RACSignal *)firebaseSignalForItemNumber:(NSNumber *)itemNumber {
    return WSM_LAZY(self.firebaseSignalDictionary[[itemNumber stringValue]], ({
        RACSubject *storySubject = RACSubject.subject;
        RACSignal *replay = storySubject.replayLast;
        __block CBLDocument *storyDoc = [self documentForItemNumber:itemNumber];
        Firebase *base = [self.itemsAPI childByAppendingPath:[itemNumber stringValue]];
        @weakify(storySubject);
        [base observeEventType:FEventTypeValue withBlock:^(FDataSnapshot *snapshot) {
            @strongify(storySubject);
            if (snapshot.value) {
                NSError *error;
                [storyDoc mergeUserProperties:snapshot.value error:&error];
                WSMLog(error, @"Error merging doc after Firebase Event: %@", error);
                [storySubject sendNext:storyDoc];
            }
        }];
        @weakify(self);
        [storySubject doCompleted:^{
            @strongify(self);
            [base removeAllObservers];
            [self.firebaseSignalDictionary removeObjectForKey:[itemNumber stringValue]];
        }];
        
        [storySubject sendNext:storyDoc];
        replay;
    }));
}

- (UIImage *)getPlaceholderAndFaviconForItemNumber:(NSNumber *)itemNumber
                                          callback:(void(^)(UIImage *favicon))completion {
    CBLDocument *storyDoc = [self documentForItemNumber:itemNumber];
    NSString *hostURL = [self schemeAndHostFromURLString:storyDoc[@"url"]];
    if (!hostURL) {
        completion(nil);
        return self.faviconCache[webPlaceHolderName];
    } else {
        HNFavicon *model = [self modelForFaviconKey:hostURL];
        if (self.faviconCache[hostURL]) {
            completion(nil);
        } else if (!self.faviconCache[hostURL] && model.attachmentNames) {
            CBLAttachment *attachment = [model attachmentNamed:model.attachmentNames.firstObject];
            completion(nil);
            self.faviconCache[hostURL] = [[UIImage alloc] initWithData:attachment.content];
        } else {
            self.faviconCache[hostURL] = self.faviconCache[webPlaceHolderName];
            [self getFaviconFrom:[hostURL stringByAppendingString:@"/favicon.ico"]
                      completion:^(UIImage *favicon)
             {
                 if (favicon) {
                     [self saveFavicon:favicon onDisk:model inMemory:hostURL];
                     completion(favicon);
                     return;
                 }
                 [self getFaviconFrom:[NSString stringWithFormat:
                                       @"http://www.google.com/s2/favicons?domain=%@", hostURL]
                           completion:^(UIImage *favicon)
                  {
                      if (favicon) {
                          [self saveFavicon:favicon onDisk:model inMemory:hostURL];
                          completion(favicon);
                      } else {
                          completion(nil);
                      }
                  }];
             }];
        }
    }
    return self.faviconCache[hostURL];
}

- (void)getFaviconFrom:(NSString *)hostURL completion:(void(^)(UIImage *favicon))completion {
    NSURL *faviconURL = [NSURL URLWithString:[hostURL stringByAppendingString:@"/favicon.ico"]];
    NSURLRequest *request = [NSURLRequest requestWithURL:faviconURL];
    self.httpManager.responseSerializer = [AFImageResponseSerializer serializer];
    [[self.httpManager HTTPRequestOperationWithRequest:request
                                               success:^(AFHTTPRequestOperation *operation,
                                                         id responseObject) {
                                                   completion(responseObject);
                                               } failure:^(AFHTTPRequestOperation *operation,
                                                           NSError *error) {
                                                   completion(nil);
                                               }] start];
}

- (void)saveFavicon:(UIImage *)image onDisk:(HNFavicon *)fModel inMemory:(NSString *)hostURL {
    self.faviconCache[hostURL] = image;
    [fModel setAttachmentNamed:@"favicon"
               withContentType:@"image/png"
                       content:UIImagePNGRepresentation(image)];
    NSError *error;
    [fModel save:&error];
    WSMLog(error, @"Error Saving Attachment: %@", error);
}

- (void)hideStory:(NSNumber *)number {
    NSArray *array = self.currentUser.hiddenStories;
    self.currentUser.hiddenStories = [array arrayByAddingObject:number];
    NSError *error;
    [self.currentUser save:&error];
    WSMLog(error, @"User Could Not Hide Story: %@", error);
    self.currentTopStories = [self topStoriesWithCurrentFilters];
}

#pragma mark - Helper Methods

- (HNFavicon *)modelForFaviconKey:(NSString *)key {
    CBLDocument *doc = [self.newsDatabase documentWithID:key];
    if (!doc.properties) {
        NSError *error;
        [doc mergeUserProperties:@{@"_id":key, @"type":@"HNFavicon"} error:&error];
        WSMLog(error, @"Failed merging Favicon Document: %@",error);
    }
    return [HNFavicon modelForDocument:doc];
}
- (CBLDocument *)documentForItemNumber:(NSNumber *)number {
    CBLDocument *doc = [self.newsDatabase documentWithID:number.stringValue];
    if (!doc.userProperties) {
        NSError *error;
        [doc mergeUserProperties:@{@"by":@"rismay",
                                   @"id":@0,
                                   @"kids":@[],
                                   @"score":@0,
                                   @"text":@"",
                                   @"time":@0,
                                   @"title":@"Fetching Story...",
                                   @"type":@"story",
                                   @"url":@""}
                           error:&error];
        if (error) {
            NSLog(@"Error Saving initial doc: %@, %@", error, doc.properties);
        }
    }
    return doc;
}

- (UIImage *)faviconForKey:(NSString *)key {
    return self.faviconCache[key];
}

- (NSString *)schemeAndHostFromURLString:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    if (url.scheme && url.host) {
        return [NSString stringWithFormat:@"%@://%@", url.scheme, url.host];
    }
    return nil;
}

@end
