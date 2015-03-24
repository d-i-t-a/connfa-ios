//
//  The MIT License (MIT)
//  Copyright (c) 2014 Lemberg Solutions Limited
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//   The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

#import "DCMainProxy.h"
#import "DCEvent+DC.h"
#import "DCMainEvent+DC.h"
#import "DCBof+DC.h"
#import "DCType+DC.h"
#import "DCTime+DC.h"
#import "DCTimeRange+DC.h"
#import "DCSpeaker+DC.h"
#import "DCLevel+DC.h"
#import "DCTrack+DC.h"
#import "DCLocation+DC.h"
#import "DCFavoriteEvent.h"

#import "NSDate+DC.h"
#import "NSUserDefaults+DC.h"

#import "Reachability.h"
#import "DCDataProvider.h"
#import "DCWebService.h"
#import "DCParserService.h"
#import "NSManagedObject+DC.h"
#import "DCCoreDataStore.h"

#import "DCManagedObjectUpdateProtocol.h"

//TODO: remove import after calendar will be intagrated
#import "AppDelegate.h"
#import "DCLocalNotificationManager.h"
#import "DCLoginViewController.h"
//

#import "DCImportDataSevice.h"

const NSString * INVALID_JSON_EXCEPTION = @"Invalid JSON";



#pragma mark - block declaration

typedef void(^UpdateDataFail)(NSString *reason);

#pragma mark -

@interface DCMainProxy () <DCImportDataSeviceDelegate>

@property (nonatomic, copy) void(^dataReadyCallback)(DCMainProxyState mainProxyState);
//
@property (strong, nonatomic) DCImportDataSevice *importDataService;

@end

#pragma mark -
#pragma mark -

@implementation DCMainProxy

@synthesize managedObjectModel=_managedObjectModel,
workContext=_workContext,
defaultPrivateContext=_defaultPrivateContext,
persistentStoreCoordinator=_persistentStoreCoordinator;

#pragma mark - initialization



+ (DCMainProxy*)sharedProxy
{
    static id sharedProxy = nil;
    static dispatch_once_t disp;
    dispatch_once(&disp, ^{
        sharedProxy = [[self alloc] init];
        [sharedProxy initialise];
    });
    return sharedProxy;
}

- (void)initialise
{
    
    // Initialise import data service
    
    self.importDataService = [[DCImportDataSevice alloc] initWithManagedObjectContext:[DCCoreDataStore defaultStore] andDelegate:self];
    // Set default data
    [self setState:(![self.importDataService isInitDataImport])? DCMainProxyStateDataReady : DCMainProxyStateNoData];
}


- (void)setDataReadyCallback:(void (^)(DCMainProxyState))dataReadyCallback
{
    if (self.state == DCMainProxyStateDataReady)
    {
        if (dataReadyCallback) {
                dataReadyCallback(self.state);
        }
        
    }
    
    _dataReadyCallback = dataReadyCallback;
}

#pragma mark - public

- (void)update
{
    _workContext = [self newMainQueueContext];
    if (self.state == DCMainProxyStateInitDataLoading ||
        self.state == DCMainProxyStateDataLoading)
    {
        NSLog(@"data is already in loading progress");
        return;
    }
    else if (self.state == DCMainProxyStateNoData)
    {
        [self setState:DCMainProxyStateInitDataLoading];
    }
    else
    {
        [self setState:DCMainProxyStateDataLoading];
    }
    
    [self startNetworkChecking];
}

#pragma mark -

- (void)startNetworkChecking
{
//    Reachability * reach = [Reachability reachabilityWithHostname:SERVER_URL];
    Reachability * reach = [Reachability reachabilityWithHostname:@"google.com"];
    if (reach.isReachable)
    {
        [self updateEvents];
    }
    else
    {
        if (self.state == DCMainProxyStateInitDataLoading)
        {
            [self setState:DCMainProxyStateNoData];
            dispatch_async(dispatch_get_main_queue(), ^{
                [[[UIAlertView alloc] initWithTitle:@"Attention"
                                            message:@"Internet connection is not available at this moment. Please, try later"
                                           delegate:nil
                                  cancelButtonTitle:@"Ok"
                                  otherButtonTitles:nil] show];
            });
        }
        else
        {
            [self setState:DCMainProxyStateLoadingFail];
            [self dataIsReady];
        }
    }
    return;
}



#pragma mark Import data from server

- (void)updateEvents
{
    [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
    //  Import data from the external storage

    [self.importDataService chechUpdates];
}

#pragma mark
- (void)importDataServiceFinishedImport:(DCImportDataSevice *)importDataService withStatus:(DCImportDataSeviceImportStatus)status
{
    switch (status) {
        case DCDataUpdateFailed: {
            [self setState:DCMainProxyStateLoadingFail];
            NSLog(@"Update failed");
            break;
        }
        case DCDataNotChanged:
        case DCDataUpdateSuccess: {
            [self setState:DCMainProxyStateDataReady];
            [self dataIsReady];
            break;
        }
            
        default:
            break;
    }
    [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
}

- (void)dataIsReady
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.dataReadyCallback) {
            self.dataReadyCallback(self.state);
        }
    });

}

#pragma mark - getting instances

- (NSArray *)eventsWithIDs:(NSArray *)iDs
#warning this method used by LocalNotification process. Can be obsolated
{
    NSPredicate * predicate = [NSPredicate predicateWithFormat:@"eventID IN %@", iDs];
    NSArray *results = [self instancesOfClass:[DCEvent class]
                         filtredUsingPredicate:predicate
                                     inContext:self.defaultPrivateContext];
    return results;
}

- (NSArray*)getAllInstancesOfClass:(Class)aClass inMainQueue:(BOOL)mainQueue
{
    return [self getAllInstancesOfClass:aClass predicate:nil inMainQueue:mainQueue];
}

- (NSArray*)getAllInstancesOfClass:(Class)aClass predicate:(NSPredicate*)aPredicate inMainQueue:(BOOL)mainQueue
{
    return [self instancesOfClass:aClass filtredUsingPredicate:aPredicate inContext:self.newMainQueueContext];
}

- (NSManagedObject*)objectForID:(int)ID ofClass:(Class)aClass inContext:(NSManagedObjectContext *)context
{
    if ([aClass conformsToProtocol:@protocol(ManagedObjectUpdateProtocol)]) {
        return [self getObjectOfClass:aClass forID:ID whereIdKey:[aClass idKey] inContext:context];
    }
    else
    {
        @throw [NSException exceptionWithName:[NSString stringWithFormat:@"%@",NSStringFromClass(aClass)]
                                       reason:@"Do not conform protocol"
                                     userInfo:nil];
        return nil;
    }
}


#pragma mark -

- (NSManagedObject*)getObjectOfClass:(Class)class forID:(NSInteger)ID whereIdKey:(NSString*)idKey inContext:(NSManagedObjectContext *)context
{
    NSPredicate * predicate = [NSPredicate predicateWithFormat:@"%K = %i", idKey, ID];
    NSArray * results = [self instancesOfClass:class
                         filtredUsingPredicate:predicate
                                     inContext:context];
    if (results.count > 1)
    {
        @throw [NSException exceptionWithName:[NSString stringWithFormat:@"%@",class]
                                       reason:[NSString stringWithFormat:@"too many objects id# %li",ID]
                                     userInfo:nil];
    }
    return (results.count ? [results firstObject] : nil);
}



#pragma mark - Operation with favorites

- (void)addToFavoriteEvent:(DCEvent *)event
{
    DCFavoriteEvent *favoriteEvent = [DCFavoriteEvent createManagedObjectInContext:self.newMainQueueContext];//(DCFavoriteEvent*)[self createObjectOfClass:[DCFavoriteEvent class]];
    favoriteEvent.eventID = event.eventID;
    [DCLocalNotificationManager scheduleNotificationWithItem:event interval:10];
    [self saveContext];
}

- (void)removeFavoriteEventWithID:(NSNumber *)eventID
{
    DCFavoriteEvent *favoriteEvent = (DCFavoriteEvent*)[self objectForID:[eventID intValue]
                                                                 ofClass:[DCFavoriteEvent class]
                                                               inContext:self.defaultPrivateContext];
    if (favoriteEvent) {
        [DCLocalNotificationManager cancelLocalNotificationWithId:favoriteEvent.eventID];
        [self removeItem:favoriteEvent];
    }
}

- (void)openLocalNotification:(UILocalNotification *)localNotification
{
    // FIXME: Rewrite this code. It create stack with favorite controller and event detail controller.
    UINavigationController *navigation = (UINavigationController *)[(AppDelegate*)[[UIApplication sharedApplication] delegate] window].rootViewController;
    [navigation popToRootViewControllerAnimated:NO];
    NSNumber *eventID = localNotification.userInfo[@"EventID"];
    NSArray *event = [[DCMainProxy sharedProxy] eventsWithIDs:@[eventID]];
    [(DCLoginViewController *)[navigation topViewController] openEventFromFavoriteController:[event firstObject]];
    
}

- (void)loadHtmlAboutInfo:(void(^)(NSString *))callback
{
    callback([NSUserDefaults aboutString]);
}

#pragma mark - DO save/not save/delete

- (void)saveContext
{
    NSError * err = nil;
    [self.defaultPrivateContext save:&err];
    if (err)
    {
        NSLog(@"WRONG! context save");
    }
}

- (void)removeItem:(NSManagedObject*)item
{
    [self.defaultPrivateContext deleteObject:item];
}

- (void)rollbackUpdates
{
    [self.defaultPrivateContext rollback];
}




#pragma mark - Core Data stack


- (NSManagedObjectContext*)defaultPrivateContext
{

    return [DCCoreDataStore privateQueueContext];
}

-(NSManagedObjectContext*)newMainQueueContext
{

    return [DCCoreDataStore mainQueueContext];
}

#pragma mark -

- (NSArray *)executeFetchRequest:(NSFetchRequest *)fetchRequest inContext:(NSManagedObjectContext *)context
{
    @try {
        NSArray *result = [context executeFetchRequest:fetchRequest error:nil];
        if(result && [result count])
        {
            return result;
        }
    }
    @catch (NSException *exception) {
        NSLog(@"%@", NSStringFromClass([self class]));
        NSLog(@"%@", [context description]);
        NSLog(@"%@", [context.persistentStoreCoordinator description]);
        NSLog(@"%@", [context.persistentStoreCoordinator.managedObjectModel description]);
        NSLog(@"%@", [context.persistentStoreCoordinator.managedObjectModel.entities description]);
        @throw exception;
    }
    @finally {
        
    }
    return nil;
}

- (NSArray*) instancesOfClass:(Class)objectClass filtredUsingPredicate:(NSPredicate *)predicate inContext:(NSManagedObjectContext *)context
{
    NSEntityDescription *entityDescription = [NSEntityDescription entityForName:NSStringFromClass(objectClass) inManagedObjectContext:context];
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] init];
    [fetchRequest setEntity:entityDescription];
    [fetchRequest setReturnsObjectsAsFaults:NO];
    [fetchRequest setPredicate:predicate];
    return [self executeFetchRequest:fetchRequest inContext:context];
}

- (NSArray *)valuesFromProperties:(NSArray *)values forInstanceOfClass:(Class)objectClass inContext:(NSManagedObjectContext *)context
{
    NSEntityDescription *entityDescription = [NSEntityDescription entityForName:NSStringFromClass(objectClass) inManagedObjectContext:context];
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] init];
    [fetchRequest setEntity:entityDescription];
    [fetchRequest setResultType:NSDictionaryResultType];
    [fetchRequest setPropertiesToFetch:values];
    [fetchRequest setReturnsObjectsAsFaults:NO];
    return [self executeFetchRequest:fetchRequest inContext:context];
}

- (id) createInstanceOfClass:(Class)instanceClass inContext:(NSManagedObjectContext *)context
{
    NSEntityDescription *entityDescription = [NSEntityDescription entityForName:NSStringFromClass(instanceClass)  inManagedObjectContext:context];
    NSManagedObject *result = [[NSManagedObject alloc] initWithEntity:entityDescription insertIntoManagedObjectContext:context];
    return result;
}

@end