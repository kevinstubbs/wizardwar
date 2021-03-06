//
//  LocalPartyService.m
//  WizardWar
//
//  Created by Sean Hess on 6/1/13.
//  Copyright (c) 2013 The LAB. All rights reserved.
//

#import "LobbyService.h"
#import "User.h"
#import "IdService.h"
#import "NSArray+Functional.h"
#import "LocationService.h"
#import "UserService.h"
#import "ObjectStore.h"
#import <Firebase/Firebase.h>
#import "ConnectionService.h"
#import <ReactiveCocoa.h>
#import "UserFriendService.h"
#import "InfoService.h"

// Just implement global people for this yo
@interface LobbyService ()
@property (nonatomic, strong) Firebase * lobby;
@property (nonatomic, strong) Firebase * serverTimeOffset;
@property (nonatomic, strong) CLLocation * currentLocation;
@property (nonatomic, strong) User * joinedUser;
@property (nonatomic) BOOL joining;
@property (nonatomic) NSTimeInterval serverOffset;
- (void)leaveLobby:(User*)user;
@end

// Use location is central to LOBBY

@implementation LobbyService

+ (LobbyService *)shared {
    static LobbyService *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[LobbyService alloc] init];
        instance.joined = NO;
        instance.joining = NO;
        
    });
    return instance;
}

- (void)connect:(Firebase *)root {
    
    NSLog(@"LobbyService: connect");
    [self setAllOffline];
    
    self.lobby = [root childByAppendingPath:@"lobby"];
    self.serverTimeOffset = [root childByAppendingPath:@".info/serverTimeOffset"];
    
    __weak LobbyService * wself = self;
    
    [self.serverTimeOffset observeEventType:FEventTypeValue withBlock:^(FDataSnapshot *snapshot) {
        if (snapshot.value == [NSNull null]) return;
        wself.serverOffset = [(NSNumber *)snapshot.value doubleValue]/1000.0;
        [wself calculateServerTime];
    }];

    [self.lobby observeEventType:FEventTypeChildAdded withBlock:^(FDataSnapshot *snapshot) {
        [wself onAdded:snapshot];
    }];
    
    [self.lobby observeEventType:FEventTypeChildRemoved withBlock:^(FDataSnapshot *snapshot) {
        [wself onRemoved:snapshot];
    }];
    
    [self.lobby observeEventType:FEventTypeChildChanged withBlock:^(FDataSnapshot *snapshot) {
        [wself onChanged:snapshot];
    }];
    
    // Monitor Connection so we can disconnect and reconnect
    [RACAble(ConnectionService.shared, isUserActive) subscribeNext:^(id x) {
        [wself onChangedIsUserActive:ConnectionService.shared.isUserActive];
    }];
    
    [RACAble(LocationService.shared, location) subscribeNext:^(id x) {
        [self setLocation:LocationService.shared.location];
    }];
}

- (void)disconnect {
    if (self.joinedUser)
        [self leaveLobby:self.joinedUser];
    self.joinedUser = nil;
    self.joined = NO;
    self.joining = NO;
    [self.lobby removeAllObservers];
    [self.serverTimeOffset removeAllObservers];
    self.lobby = nil;
    self.serverTimeOffset = nil;
}


// change all users to be offline so we can accurately sync with the server
// ALTERNATIVE: put the field on user itself and have the user change it? naww...
-(void)setAllOffline {
    NSFetchRequest * request = [UserService.shared requestOtherOnline:UserService.shared.currentUser];
    NSArray * users = [ObjectStore.shared requestToArray:request];
    
    [users forEach:^(User * user) {
        [self setUserOffline:user];
    }];
}

-(void)calculateServerTime {
    self.currentServerTime = [[NSDate date] timeIntervalSince1970] + self.serverOffset;
}


// Guaranteed: that we have currentLocation at this point
-(void)onAdded:(FDataSnapshot *)snapshot {

    // It doesn't matter if this arrives before the user object
    // it will just add the isOnline, locationLatitude, locationLongitude
    
    User * user = [UserService.shared userWithId:snapshot.name create:YES];
    [user setValuesForKeysWithDictionary:snapshot.value];
    user.joined = ([snapshot.value[@"joined"] doubleValue] / 1000.0);
    if (user.joined > self.currentServerTime)
        [self calculateServerTime];
    user.isOnline = YES;
    
    if (user != UserService.shared.currentUser) {
        self.totalInLobby++;
    }

    // Come through later and add distance!
    if (self.currentLocation)
        user.distance = [self.currentLocation distanceFromLocation:user.location];
    else
        user.distance = kLocationDistanceInvalid;
    
    NSLog(@"LobbyService: (+) name=%@ distance=%f", user.name, user.distance);
}

-(void)onRemoved:(FDataSnapshot*)snapshot {
    User * removed = [UserService.shared userWithId:snapshot.name];
    if (removed) {
        
        if (removed != UserService.shared.currentUser) {
            self.totalInLobby--;
        }
        
        NSLog(@"LobbyService: (-) %@", removed.name);
        [self setUserOffline:removed];
    }
}

-(void)setUserOffline:(User*)user {
    user.isOnline = NO;
    user.locationLatitude = 0;
    user.locationLongitude = 0;
}

-(void)onChanged:(FDataSnapshot*)snapshot {
    [self onAdded:snapshot];
}

// I DO need to leave the lobby if inactive, because it can happen on app close
-(void)onChangedIsUserActive:(BOOL)active {
    // ignore unless we've already joined once
    if (!self.joinedUser) return;
    
    if (active) {
        [self joinLobby:self.joinedUser];
    } else {
        [self leaveLobby:self.joinedUser];
    }
}

// set isJoined:(User*)user is 

// Maybe we should have this OBSERVE the location service for the location?
- (void)setLocation:(CLLocation *)location {
    self.currentLocation = location;
    
    if (!self.currentLocation) return;
    
    NSLog(@"LobbyService: Location!");
    
    // Update the location if already joined
    if ((self.joined || self.joining) && self.joinedUser) {
        self.joinedUser.locationLongitude = self.currentLocation.coordinate.longitude;
        self.joinedUser.locationLatitude = self.currentLocation.coordinate.latitude;
        [self saveUserToLobby:self.joinedUser];
    }
    
    // Also update the distance to anyone else already in the system
    NSArray * usersWithLocations = [ObjectStore.shared requestToArray:[self requestUsersWithLocations]];
    [usersWithLocations forEach:^(User*user) {
        user.distance = [self.currentLocation distanceFromLocation:user.location];
    }];
}


// Joins us to the lobby, por favor!
// MAKE SURE that the location is set before doing this!
- (void)joinLobby:(User *)user {
    if (self.joined || self.joining) return;
    NSLog(@"LobbyService: (JOIN)");

    self.joined = NO;
    self.joining = YES;
    self.joinedUser = user;
    
    // If we have a location, save that too
    if (self.currentLocation) {
        user.locationLongitude = self.currentLocation.coordinate.longitude;
        user.locationLatitude = self.currentLocation.coordinate.latitude;
    }
    user.version = [InfoService version];
    
    [self saveUserToLobby:user];
}

- (void)saveUserToLobby:(User*)user {
    Firebase * node = [self.lobby childByAppendingPath:user.userId];
    
    NSMutableDictionary * object = [NSMutableDictionary dictionaryWithDictionary:user.toLobbyObject];
    object[@"joined"] = kFirebaseServerValueTimestamp;
    
    [node onDisconnectRemoveValue];
    [node setValue:object withCompletionBlock:^(NSError *error, Firebase *ref) {
        self.joined = YES;
        self.joining = NO;
        [self calculateServerTime];
        NSLog(@"LobbyService: (joined)");
    }];    
}


- (void)leaveLobby:(User*)user {
    if (!self.joined) return;
    NSLog(@"LobbyService: (LEAVE)");
    self.joined = NO;
    if (!user.userId) return;
    // comment out to test disconnecting
    Firebase * node = [self.lobby childByAppendingPath:user.userId];
    [node removeValue];
}


- (void)user:(User *)user joinedMatch:(NSString *)matchId {
    user.activeMatchId = matchId;
    [self saveUserToLobby:user];
}

- (void)userLeftMatch:(User*)user {
    user.activeMatchId = nil;
    [self saveUserToLobby:user];
}

-(NSPredicate*)predicateNotFriend:(User*)user {
    return [NSCompoundPredicate notPredicateWithSubpredicate:[UserFriendService.shared predicateIsFBFriendOrFrenemy:user]];
}

#pragma mark - Core Data Requests

- (NSFetchRequest*)requestCloseUsers:(User *)user {
    NSFetchRequest * request = [UserService.shared requestOtherOnline:user];
    NSPredicate * isClose = [NSPredicate predicateWithFormat:@"distance >= 0 AND distance < %f", MAX_SAME_LOCATION_DISTANCE];
    // they also must be online...
    
    // We allow friends in close one
//    request.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[isClose, [self predicateNotFriend:user], request.predicate]];
    request.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[isClose, request.predicate]];
    return request;
}

// not friends
- (NSFetchRequest*)requestClosestUsers:(User *)user withLimit:(NSInteger)limit {
    NSFetchRequest * request = [UserService.shared requestOtherOnline:user];

    NSPredicate * notFriend = [self predicateNotFriend:user];
    NSPredicate * isFar = [NSPredicate predicateWithFormat:@"distance > %f", MAX_SAME_LOCATION_DISTANCE];
    request.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[notFriend, isFar, request.predicate]];
    
    NSSortDescriptor * sortDistance = [NSSortDescriptor sortDescriptorWithKey:@"distance" ascending:YES];
    request.sortDescriptors = @[sortDistance];
    
    request.fetchLimit = limit;
    
    return request;
}

- (NSFetchRequest*)requestRecentUsers:(User *)user withLimit:(NSInteger)limit {
    NSFetchRequest * request = [UserService.shared requestOtherOnline:user];
    NSPredicate * notFriend = [self predicateNotFriend:user];
    request.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[notFriend, request.predicate]];
    NSSortDescriptor * sortDistance = [NSSortDescriptor sortDescriptorWithKey:@"joined" ascending:NO];
    request.sortDescriptors = @[sortDistance];
    request.fetchLimit = limit;
    return request;
}



- (NSFetchRequest*)requestUsersWithLocations {
    User * user = UserService.shared.currentUser;
    NSFetchRequest * request = [UserService.shared requestOtherOnline:user];
    NSPredicate * hasLocation = [NSPredicate predicateWithFormat:@"locationLatitude > 0"];
    request.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[hasLocation, request.predicate]];
    return request;    
}

@end
