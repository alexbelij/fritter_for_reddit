import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:draw/draw.dart';
import 'package:flutter/material.dart';
import 'package:fritter_for_reddit/exports.dart';

//import 'package:fritter_for_reddit/models/subreddit_info/rule.dart';
import 'package:fritter_for_reddit/utils/extensions.dart';

import 'package:fritter_for_reddit/helpers/functions/misc_functions.dart';
import 'package:fritter_for_reddit/models/postsfeed/posts_feed_entity.dart';
import 'package:fritter_for_reddit/models/subreddit_info/subreddit_information_entity.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:rxdart/rxdart.dart';

part 'feed_provider.g.dart';

class FeedProvider with ChangeNotifier {
  Box<SubredditInfo> _cache;

  final Reddit reddit = GetIt.I.get<Reddit>();
  final SecureStorageHelper _storageHelper = SecureStorageHelper();

  BehaviorSubject<PostsFeedEntity> _postFeedStream = BehaviorSubject();

  PostsFeedEntity get postFeed => _postFeedStream.value;

  BehaviorSubject<String> currentSubredditStream =
      BehaviorSubject.seeded('frontpage');

  String get currentSubreddit => currentSubredditStream.value;

  BehaviorSubject<SubredditInformationEntity>
      currentSubredditInformationStream = BehaviorSubject.seeded(null);

  /// Note: This stream is only updated when the SubredditInfo and the subreddit feed has been updated.
  /// It will not update if you add more data to an existing stream. It's a ZipStream, not a CombineLatestStream.
  BehaviorSubject<SubredditInfo> subStream;
  bool subLoadingError = false;

  String sort = "Hot";

  String subListingFetchUrl = "";

  bool subInformationLoadingError = false;

  bool feedInformationLoadingError = false;

  ViewState _state;

  ViewState _partialState;
  ViewState _loadMorePostsState = ViewState.Idle;
  CurrentPage currentPage;

  ViewState get loadMorePostsState => _loadMorePostsState;

  ViewState get partialState => _partialState;

  ViewState get state => _state;

  SubredditInformationEntity get subredditInformationEntity =>
      currentSubredditInformationStream.value;

  FeedProvider({
    this.currentPage = CurrentPage.frontPage,
    String currentSubreddit = '',
  }) {
    _init();
  }

  void _init() {
    _fetchPostsListing(subredditName: currentSubreddit);
    currentSubredditStream.listen((name) {
      debugPrint('updating currentSubredditStream to $name');
    });
    _postFeedStream.listen((feed) {
      debugPrint('updating postFeedStream');
      final posts = feed.data.children;
      assert(posts.map((post) => post.data.id).toSet().length == posts.length,
          'Duplicate posts have been detected.');
    });
    currentSubredditInformationStream.listen((subredditInformation) {
      debugPrint('updating currentSubredditStream to '
          '${subredditInformation?.data?.displayName ?? 'NO DATA for this sub'}');
    });

    subStream = ZipStream<dynamic, SubredditInfo>([
      _postFeedStream,
      currentSubredditInformationStream,
      currentSubredditStream
    ], (streams) {
      final postFeed = streams[0];
      final currentSubredditInformation = streams[1];
      var currentSubreddit = streams[2];
      return SubredditInfo(
        name: currentSubreddit,
        postsFeed: postFeed,
        subredditInformation: currentSubredditInformation,
      );
    }).asBehaviorSubject
      ..listen((subredditInfo) {
        notifyListeners();
//        return _cache.put(subredditInfo.name, subredditInfo); TODO: Uncomment when we re-enable caching
      });
  }

  factory FeedProvider.openFromName(String currentSubreddit) {
    return FeedProvider(
        currentPage: CurrentPage.other, currentSubreddit: currentSubreddit);
  }

  Future<Stream<Map>> accessCodeServer() async {
    final StreamController<Map> onCode = StreamController();
    HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 8080);
    server.listen((HttpRequest request) async {
//      // print("Server started");
      final Map<String, String> response = request.uri.queryParameters;
//      // print(request.uri.pathSegments);
      request.response
        ..statusCode = 200
        ..headers.set("Content-Type", ContentType.html.mimeType)
        ..write(
            '<html><meta name="viewport" content="width=device-width, initial-scale=1.0"><body> <h2 style="text-align: center; position: absolute; top: 50%; left: 0: right: 0">Welcome to Fritter</h2><h3>You can close this window<script type="javascript">window.close()</script> </h3></body></html>');
      await request.response.close();
      await server.close(force: true);
      onCode.add(response);
      await onCode.close();
    });
    return onCode.stream;
  }

  PostsFeedEntity appendMediaType(PostsFeedEntity postFeed) {
    for (var x in postFeed.data.children) {
      x.data.postType = getMediaType(x.data)['media_type'];
    }
    return postFeed;
  }

  /// action being true results in subscribing to a subreddit
  Future<void> changeSubscriptionStatus(String subId, bool action) async {
    _partialState = ViewState.busy;
    notifyListeners();

    String authToken = await _storageHelper.authToken;
    final url = "https://oauth.reddit.com/api/subscribe";

    http.Response subInfoResponse;
    if (action) {
      subInfoResponse = await http.post(
        url + '?action=sub&sr=$subId&skip_initial_defaults=true&X-Modhash=null',
        headers: {
          'Authorization': 'bearer ' + authToken,
          'User-Agent': 'fritter_for_reddit by /u/SexusMexus',
        },
      );
    } else {
      subInfoResponse = await http.post(
        url + '?action=unsub&sr=$subId&X-Modhash=null',
        headers: {
          'Authorization': 'bearer ' + authToken,
          'User-Agent': 'fritter_for_reddit by /u/SexusMexus',
        },
      );
    }
    subredditInformationEntity.data.userIsSubscriber =
        !subredditInformationEntity.data.userIsSubscriber;
    _partialState = ViewState.Idle;
    notifyListeners();
  }

  @override
  void dispose() {
    currentSubredditInformationStream.close();
    currentSubredditStream.close();
    subStream.close();
    _postFeedStream.close();
    super.dispose();
  }

  Future<void> _fetchPostsListing({
    String subredditName = '',
    Sort sortType = Sort.hot,
    bool loadingTop = false,
    int limit = 10,
  }) async {
    if (subredditName == 'frontPage') {
      return reddit.front.hot();
    }
    final SubredditRef subreddit = reddit.subreddit(subredditName);
    return;
  }

  RedditorRef fetchUserInfo(String username) {
    return reddit.redditor(username);
  }

  Future<void> authenticateUser(BuildContext context) async {
    final url =
        "https://www.reddit.com/api/v1/${PlatformX.isDesktop ? 'authorize' : 'authorize.compact'}?client_id=" +
            CLIENT_ID +
            "&response_type=code&state=randichid&redirect_uri=http://localhost:8080/&duration=permanent&scope=identity,edit,flair,history,modconfig,modflair,modlog,modposts,modwiki,mysubreddits,privatemessages,read,report,save,submit,subscribe,vote,wikiedit,wikiread";
    // TODO: Embed a WebView for macOS when this is supported.
    launchURL(Theme.of(context).primaryColor, url);
    bool res = false; //await this.performAuthentication();
    // print("final res: " + res.toString());
    if (res) {
      final NavigatorState navigator = Navigator.of(context);
      await Provider.of<FeedProvider>(context, listen: false)
          .navigateToSubreddit('');
      if (!PlatformX.isDesktop && navigator.canPop()) {
        navigator.pop();
      }
    }
  }

  Future<SubredditInformationEntity> fetchSubredditInformationOAuth(
    String token,
    String currentSubreddit,
  ) async {
    subInformationLoadingError = false;
    final url = "https://oauth.reddit.com/r/$currentSubreddit/about";
    try {
      final subInfoResponse = await http.get(
        url,
        headers: {
          'Authorization': 'bearer ' + token,
          'User-Agent': 'fritter_for_reddit by /u/SexusMexus',
        },
      ).catchError((e) {
        // // print("Error fetching Subreddit information");
        throw new Exception("Error");
      });

      if (subInfoResponse.statusCode == 200) {
        debugPrint('updating currentSubredditInformationStream');

        currentSubredditInformationStream.value =
            SubredditInformationEntity.fromJson(
                json.decode(subInfoResponse.body));

        // // print(json.decode((subInfoResponse.body).toString()));
        if (subredditInformationEntity.data.title == null) {
          subInformationLoadingError = true;
        }
      } else {
        debugPrint('updating currentSubredditInformationStream');
        currentSubredditInformationStream.value = null;
      }
    } catch (e) {
      // // print(e.toString());
    }
    return subredditInformationEntity;
  }

  Future<PostsFeedEntity> loadMorePosts() async {
    _loadMorePostsState = ViewState.busy;
    notifyListeners();

    await _storageHelper.init();
    String url = "";
    try {
      url = subListingFetchUrl + "&after=${postFeed.data.after}";
      http.Response subredditResponse;
      if (_storageHelper.signInStatus) {
        if (await _storageHelper.needsTokenRefresh()) {
          await _storageHelper.performTokenRefresh();
        }
        // // print(url);
        String token = await _storageHelper.authToken;
        subredditResponse = await http.get(
          url,
          headers: {
            'Authorization': 'bearer ' + token,
            'User-Agent': 'fritter_for_reddit by /u/SexusMexus',
          },
        );
        // // print(subredditResponse.statusCode.toString() +
//            subredditResponse.reasonPhrase);
        // // print("previous after: " + _postFeed.data.after);
        // // print("new after : " + newData.data.after);
      } else {
        subredditResponse = await http.get(
          url,
          headers: {
            'User-Agent': 'fritter_for_reddit by /u/SexusMexus',
          },
        );
        // print(subredditResponse.statusCode.toString() +
//            subredditResponse.reasonPhrase);
      }
      final PostsFeedEntity newData =
          PostsFeedEntity.fromJson(json.decode(subredditResponse.body));
      appendMediaType(newData);
      _postFeedStream.value = postFeed.copyWith(
        data: postFeed.data.copyWith(
          children: postFeed.data.children..addAll(newData.data.children),
          after: newData.data.after,
        ),
      );
    } catch (e) {
      print("EXCEPTION : " + e.toString());
    }
    _loadMorePostsState = ViewState.Idle;
    notifyListeners();
    return postFeed;
  }

  Future<void> navigateToSubreddit(String subreddit) async {
    final String strippedSubreddit =
        subreddit.replaceFirst(RegExp(r'\/r\/| r\/'), '').replaceAll('.', '');

    if (strippedSubreddit != subStream.value.name) {
      debugPrint('updating currentSubredditStream');

      currentSubredditStream.value = strippedSubreddit;
      await _fetchPostsListing(subredditName: strippedSubreddit);

      String token = await _storageHelper.authToken;
      await fetchSubredditInformationOAuth(token, currentSubreddit);
    } else {
      debugPrint('Requesting the same subreddit. Ignoring');
      assert(subStream.value.name == strippedSubreddit,
          "These don't actually match!");
      return;
    }
  }

  void selectProperPreviewImage() {}

  Future<void> signOutUser() async {
    _state = ViewState.busy;
    notifyListeners();
    await _storageHelper.clearStorage();
    await _fetchPostsListing();
    _state = ViewState.Idle;
    notifyListeners();
  }

  Future<bool> votePost(
      {@required PostsFeedDataChildrenData postItem, @required int dir}) async {
    await _storageHelper.init();
    notifyListeners();
    if (postItem.likes == true) {
      postItem.score--;
    } else if (postItem.likes == false) {
      postItem.score++;
    }
    if (dir == 1) {
      postItem.score++;
      postItem.likes = true;
    } else if (dir == -1) {
      postItem.score--;
      postItem.likes = false;
    } else if (dir == 0) {
      postItem.score =
          postItem.likes == true ? postItem.score-- : postItem.score++;
      postItem.likes = null;
    }
    String url = "https://oauth.reddit.com/api/vote";
    final Uri uri = Uri.https(
      'oauth.reddit.com',
      'api/vote',
      {
        'dir': dir.toString(),
        'id': postItem.name.toString(),
        'rank': '2',
      },
    );
    // // print(uri);
    final String authToken = await _storageHelper.authToken;
    http.Response voteResponse;
    voteResponse = await http.post(
      uri,
      headers: {
        'Authorization': 'bearer ' + authToken,
        'User-Agent': 'fritter_for_reddit by /u/SexusMexus',
      },
    );
    // // print("vote result" + voteResponse.statusCode.toString());
    notifyListeners();
    if (voteResponse.statusCode == 200) {
      return true;
    } else {
      return false;
    }
  }

  getUserPost(String user) {}

  void _currentSubredditListener(dynamic value) async {
    final infoUrl = "https://api.reddit.com/r/$currentSubreddit/about";
    final subInfoResponse = await http.get(
      infoUrl,
      headers: {
        'User-Agent': 'fritter_for_reddit by /u/SexusMexus',
      },
    );
    if (subInfoResponse.statusCode == 200) {
      currentSubredditInformationStream.add(SubredditInformationEntity.fromJson(
          json.decode(subInfoResponse.body)));
    } else {
      // // print(response.body);
    }
  }

  /*Future _signIn() async {
    String accessToken = await _storageHelper.authToken;
    _reddit.authSetup(CLIENT_ID, '');
    Uri authUri = _reddit.authUrl('http://localhost:8080/',
        scopes: [
          'identity',
          'edit',
          'flair',
          'history',
          'modconfig',
          'modflair',
          'modlog',
          'modposts',
          'modwiki',
          'mysubreddits',
          'privatemessages',
          'read',
          'report',
          'save',
          'submit',
          'subscribe',
          'vote',
          'wikiedit',
          'wikiread'
        ],
        state: 'samplestate');
    if (true */ /*accessToken == null*/ /*) {
      launchURL(Colors.blue, authUri.toString());

      final server = await accessCodeServer();
      final Map responseParameters = await server.first;
      accessToken = responseParameters['code'];
      _storageHelper.updateAuthToken(accessToken);
    }
    _reddit = await _reddit.authFinish(
        username: CLIENT_ID, password: '', code: accessToken);
  }*/

  static FeedProvider of(BuildContext context, {bool listen = false}) =>
      Provider.of<FeedProvider>(context, listen: listen);

  Future<void> updateSorting({String sortBy, bool loadingTop}) {
    throw UnimplementedError();
  }

  Future<void> refresh() => _fetchPostsListing(subredditName: currentSubreddit);
  List<SubredditInformationEntity> _popularSubreddits;

  Future<List<SubredditInformationEntity>> fetchPopularSubreddits() async {
    if (_popularSubreddits != null) {
      return _popularSubreddits;
    }
    final result = await _fetch(endpoint: Endpoints.popular);
    List<SubredditInformationEntity> subs = (result['data']['children'] as List)
        .map((json) => SubredditInformationEntity.fromJson(json))
        .toList();
    return _popularSubreddits = subs;
  }

  Future<List<Rule>> getSubredditRules(String subreddit) async {}

  Future<Map> _fetch({String endpoint, String token, int limit}) async {
    final url =
        "https://www.reddit.com$endpoint.json${limit != null ? '?limit=$limit' : ''}";
    http.Response response = await http.get(
      url,
      headers: {
        if (token != null) 'Authorization': 'bearer ' + token,
        'User-Agent': 'fritter_for_reddit by /u/SexusMexus',
      },
    );
    final json = jsonDecode(response.body);
    return json;
  }
}

enum QueryType { subreddit, user, post }

@HiveType(typeId: 1)
class SubredditInfo {
  @HiveField(0)
  final String name;
  @HiveField(1)
  final PostsFeedEntity postsFeed;
  @HiveField(2)
  final SubredditInformationEntity subredditInformation;

//<editor-fold desc="Data Methods" defaultstate="collapsed">

  const SubredditInfo({
    @required this.name,
    @required this.postsFeed,
    @required this.subredditInformation,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SubredditInfo &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          postsFeed == other.postsFeed &&
          subredditInformation == other.subredditInformation);

  @override
  int get hashCode =>
      name.hashCode ^ postsFeed.hashCode ^ subredditInformation.hashCode;

  @override
  String toString() => 'SubredditInfo{'
      ' name: $name, '
      ' postsFeed: $postsFeed,'
      ' subredditInformation: $subredditInformation,'
      '}';

  SubredditInfo copyWith({
    String name,
    PostsFeedEntity postsFeed,
    SubredditInformationEntity subredditInformation,
  }) =>
      SubredditInfo(
        name: name ?? this.name,
        postsFeed: postsFeed ?? this.postsFeed,
        subredditInformation: subredditInformation ?? this.subredditInformation,
      );

  Map<String, dynamic> toMap() => {
        'name': name,
        'postsFeed': this.postsFeed.toJson(),
        'subredditInformation': this.subredditInformation.toJson(),
      };

  factory SubredditInfo.fromMap(Map<String, dynamic> map) {
    return SubredditInfo(
      name: map['name'],
      postsFeed: PostsFeedEntity.fromJson(map['postsFeed']),
      subredditInformation:
          SubredditInformationEntity.fromJson(map['subredditInformation']),
    );
  }

//</editor-fold>
}

class Endpoints {
  static const String trendingSubreddits = '/api/trending_subreddits';
  static const String popular = '/subreddits/popular';

  static String subredditRules(String subreddit) => '/r/$subreddit/about/rules';
}

extension on SubredditRef {
  Stream<UserContent> sortBy(Sort sortType,
      {TimeFilter timeFilter = TimeFilter.all,
      int limit,
      String after,
      Map<String, String> params}) {
    switch (sortType) {
      case Sort.hot:
        return hot(
          limit: limit,
          after: after,
          params: params,
        );
      case Sort.newest:
        return newest(
          limit: limit,
          after: after,
          params: params,
        );

      case Sort.top:
        return top(
          timeFilter: timeFilter,
          limit: limit,
          after: after,
          params: params,
        );
    }
  }
}
