/// OpenAnime (openani.me) service.
///
/// Uses the public OpenAni API directly (no backend):
///   - GET /anime/search?q=&page=
///   - GET /anime?page=&keywords=&score=&date=
///   - GET /anime/episodes/latest?page=
///   - GET /anime/{slug}
///   - GET /anime/{slug}/season/{season}
///   - GET /anime/{slug}/season/{season}/episode/{episode}
///
/// Videos are served as direct MP4 files from a rotating CDN host:
///   {CDN}/animes/{slug}/{season}/{fileIdentifier}
///
/// Reference: openani-downloader (openani_downloader.py) and the
/// SoloAnime web client (src/utils/openAniApi.js).

library;

import 'dart:async';
import 'dart:convert';

import 'package:get/get.dart';
import 'package:hoyomi/core_services/eiga/ab_eiga_service.dart';
import 'package:hoyomi/core_services/eiga/interfaces/main.dart';

class OpenAnimeService extends ABEigaService {
  @override
  bool? get $isAuth => false;

  static const _defaultCdnHost =
      'https://de2---vn-t9g4tsan-5qcl.yeshi.eu.org';
  static const _siteUrl = 'https://openani.me';

  @override
  late final init = ServiceInit(
    name: 'OpenAnime',
    faviconUrl: OImage(src: 'https://openani.me/favicon.ico'),
    rootUrl: 'https://api.openani.me',
    settings: [
      FieldInput(
        name: 'CDN URL',
        key: 'cdn_url',
        defaultValue: _defaultCdnHost,
        placeholder: _defaultCdnHost,
        description:
            'OpenAnime video CDN host. Update this if videos fail to load '
            '(the host rotates periodically).',
        appear: true,
      ),
    ],
  );

  String get _cdnHost =>
      (getSetting(key: 'cdn_url') ?? _defaultCdnHost).replaceFirst(
        RegExp(r'/$'),
        '',
      );

  Headers get _headers =>
      Headers({'referer': _siteUrl, 'origin': _siteUrl});

  // ======================= caches =========================
  final Map<String, Future<Map<String, dynamic>>> _detailCache = {};
  final Map<String, Future<Map<String, dynamic>>> _episodeCache = {};

  Future<Map<String, dynamic>> _fetchJson(String path) async {
    final raw = await fetch('$baseUrl$path', headers: _headers);
    final json = jsonDecode(raw);
    if (json is Map<String, dynamic>) return json;
    if (json is Map) return Map<String, dynamic>.from(json);
    return {'_list': json};
  }

  Future<Map<String, dynamic>> _animeDetail(String slug) {
    return _detailCache[slug] ??= _fetchJson('/anime/$slug');
  }

  Future<Map<String, dynamic>> _episodeDetail(
    String slug,
    int season,
    String episode,
  ) {
    final key = '$slug/$season/$episode';
    return _episodeCache[key] ??= _fetchJson(
      '/anime/$slug/season/$season/episode/$episode',
    ).then((data) {
      final inner = data['episodeData'];
      if (inner is Map) return Map<String, dynamic>.from(inner);
      return data;
    });
  }

  // ======================= id helpers =====================
  /// eigaId is the bare `slug` for the first season, or `slug@<seasonNumber>`
  /// for subsequent seasons (mirrors the NguonC convention so the details
  /// page can resolve the current season from the entry eigaId).
  String _slug(String eigaId) {
    final i = eigaId.indexOf('@');
    return i < 0 ? eigaId : eigaId.substring(0, i);
  }

  Future<int> _seasonNumber(String eigaId) async {
    final i = eigaId.indexOf('@');
    if (i >= 0) {
      final n = int.tryParse(eigaId.substring(i + 1));
      if (n != null) return n;
    }

    final detail = await _animeDetail(_slug(eigaId));
    final seasons = detail['seasons'];
    if (seasons is List && seasons.isNotEmpty && seasons.first is Map) {
      final n = (seasons.first as Map)['season_number'];
      if (n is num) return n.toInt();
    }
    return 1;
  }

  // ======================= parse helpers ==================
  String? _cleanUrl(dynamic value) {
    if (value is! String || value.isEmpty) return null;
    if (value.startsWith('http')) return value;
    if (value.startsWith('//')) return 'https:$value';
    if (value.startsWith('/')) {
      return 'https://image.tmdb.org/t/p/original$value';
    }
    return value;
  }

  OImage _image(dynamic value) {
    return OImage(src: _cleanUrl(value) ?? OImage.fake, headers: _headers);
  }

  String _title(Map item) {
    return (item['turkish'] ??
            item['english'] ??
            item['romaji'] ??
            item['originalName'] ??
            item['title'] ??
            item['name'] ??
            item['japanese'] ??
            item['slug'] ??
            'Unknown')
        .toString();
  }

  List<Genre> _genres(Map item) {
    final raw = item['genres'] ?? item['genresEnglish'];
    if (raw is! List) return const [];
    return raw
        .map((g) => Genre(name: g.toString(), genreId: Genre.noId))
        .toList();
  }

  int? _yearOf(Map item) {
    final date = item['firstAirDate'] ?? item['lastAirDate'];
    if (date is! String || date.isEmpty) return null;
    final match = RegExp(r'(\d{4})').firstMatch(date);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  Eiga _parseItem(Map item) {
    final pictures = item['pictures'] as Map?;
    final notice = <String>[
      if (item['type'] != null) item['type'].toString(),
      if (item['numberOfEpisodes'] != null)
        '${item['numberOfEpisodes']} Bölüm',
    ].where((e) => e.isNotEmpty).join(' • ');

    return Eiga(
      name: _title(item),
      originalName:
          item['japanese']?.toString() ?? item['romaji']?.toString(),
      eigaId: item['slug'].toString(),
      image: _image(
        pictures?['avatar'] ?? item['poster'] ?? pictures?['banner'],
      ),
      notice: notice.isEmpty ? null : notice,
      rate: (item['tmdbScore'] as num?)?.toDouble(),
      description: item['summary']?.toString(),
    );
  }

  int _resolution(dynamic value) {
    if (value is num) return value.toInt();
    if (value is String) {
      final match = RegExp(r'\d+').firstMatch(value);
      if (match != null) return int.parse(match.group(0)!);
    }
    return 0;
  }

  String? _fansubName(Map file) {
    final fansub = file['fansub'] ?? file['Fansub'];
    if (fansub is Map) {
      return (fansub['name'] ?? fansub['secureName'] ?? fansub['title'])
          ?.toString();
    }
    if (fansub is String && fansub.isNotEmpty) return fansub;
    return null;
  }

  String? _fileIdentifier(Map file) {
    return (file['file'] ??
            file['fileIdentifier'] ??
            file['file_identifier'] ??
            file['filename'] ??
            file['url'])
        ?.toString();
  }

  List<Map> _filesOf(Map episodeData) {
    final files = episodeData['files'];
    if (files is List) return files.whereType<Map>().toList();
    return const [];
  }

  String _buildCdnUrl(String slug, int season, String fileIdentifier) {
    var file = fileIdentifier;
    var query = '';
    if (file.contains('?')) {
      final parts = file.split('?');
      file = parts.first;
      query = '?${parts.sublist(1).join('?')}';
    }
    file = file.replaceFirst(RegExp(r'^/'), '');

    final encodedFile =
        file.split('/').map(Uri.encodeComponent).join('/');
    return '$_cdnHost/animes/${Uri.encodeComponent(slug)}/$season/$encodedFile$query';
  }

  List<Map> _extractEpisodes(Map seasonData) {
    // Episodes can live in a few different places depending on the endpoint.
    final candidates = <dynamic>[
      seasonData['episodes'],
      (seasonData['season'] as Map?)?['episodes'],
      ((seasonData['season'] as Map?)?['season'] as Map?)?['episodes'],
      (seasonData['seasonData'] as Map?)?['episodes'],
    ];
    for (final candidate in candidates) {
      if (candidate is List && candidate.isNotEmpty) {
        return candidate.whereType<Map>().toList();
      }
    }
    return const [];
  }

  // ======================= API ============================
  @override
  Future<EigaHome> home() async {
    final popular$ = _fetchJson('/anime?page=1');
    final latest$ = _fetchJson('/anime/episodes/latest?page=1');

    final popularData = await popular$;
    final popular =
        (popularData['animes'] as List?)?.whereType<Map>().toList() ??
        const [];

    Map<String, dynamic>? latestData;
    try {
      latestData = await latest$;
    } catch (_) {
      latestData = null;
    }
    final latest =
        (latestData?['episodes'] as List?)?.whereType<Map>().toList() ??
        const [];

    final carousel = EigaCarousel(
      aspectRatio: 16 / 9,
      maxHeightBuilder: 0.4,
      items:
          popular.take(10).map((item) {
            final pictures = item['pictures'] as Map?;
            return EigaCarouselItem(
              image: _image(pictures?['banner'] ?? pictures?['avatar']),
              eigaId: item['slug'].toString(),
              name: _title(item),
              originalName: item['japanese']?.toString(),
              description: item['summary']?.toString(),
              type: item['type']?.toString(),
              rate: (item['tmdbScore'] as num?)?.toDouble(),
              genres: _genres(item),
            );
          }).toList(),
    );

    final categories = <HomeEigaCategory>[
      if (latest.isNotEmpty)
        HomeEigaCategory(
          name: 'Son Bölümler',
          items: latest.map(_parseItem).toList(),
        ),
      HomeEigaCategory(
        name: 'Popüler Animeler',
        categoryId: 'popular',
        items: popular.map(_parseItem).toList(),
      ),
    ];

    return EigaHome(carousel: carousel, categories: categories);
  }

  @override
  getCategory({required categoryId, required page, required filters}) async {
    final params = <String, List<String>>{'page': [page.toString()]};
    filters.forEach((key, value) {
      if (value != null && value.isNotEmpty) params[key] = value;
    });

    final url = '$baseUrl/anime';
    final raw = await fetch(
      url,
      query: UrlSearchParams(params: params),
      headers: _headers,
    );
    final json = jsonDecode(raw);

    final List list =
        json is List ? json : (json['animes'] ?? json['data'] ?? []) as List;
    final items = list.whereType<Map>().map(_parseItem).toList();
    final totalPages = json is Map ? (json['totalPages'] as num?)?.toInt() ?? 1 : 1;

    return EigaCategory(
      name: 'Animeler',
      url: url,
      items: items,
      page: page,
      totalItems: totalPages * (items.isEmpty ? 24 : items.length),
      totalPages: totalPages,
    );
  }

  @override
  getExplorer({required page, required filters}) async {
    return getCategory(categoryId: 'popular', page: page, filters: filters);
  }

  @override
  search({required keyword, required page, required filters, required quick}) async {
    final raw = await fetch(
      '$baseUrl/anime/search',
      query: UrlSearchParams(
        params: {
          'q': [keyword],
          'page': [page.toString()],
        },
      ),
      headers: _headers,
    );
    final json = jsonDecode(raw);

    final List list =
        json is List ? json : (json['animes'] ?? json['data'] ?? []) as List;
    final items = list.whereType<Map>().map(_parseItem).toList();
    final totalPages = json is Map ? (json['totalPages'] as num?)?.toInt() ?? 1 : 1;

    return EigaCategory(
      name: 'Arama: $keyword',
      url: '$baseUrl/anime/search?q=$keyword',
      items: items,
      page: page,
      totalItems: totalPages * (items.isEmpty ? 24 : items.length),
      totalPages: totalPages,
    );
  }

  @override
  getDetails(String eigaId) async {
    final slug = _slug(eigaId);
    final data = await _animeDetail(slug);

    final pictures = data['pictures'] as Map?;

    final seasonsRaw =
        (data['seasons'] as List?)?.whereType<Map>().toList() ?? const [];
    final seasons =
        seasonsRaw.isEmpty
            ? [Season(name: 'Sezon 1', eigaId: slug)]
            : seasonsRaw.indexed.map((entry) {
              final index = entry.$1;
              final season = entry.$2;
              final number = (season['season_number'] as num?)?.toInt() ??
                  (index + 1);
              return Season(
                name: (season['name'] ?? 'Sezon $number').toString(),
                eigaId: index == 0 ? slug : '$slug@$number',
              );
            }).toList();

    final studios =
        (data['productionCompanies'] as List?)
            ?.whereType<Map>()
            .map(
              (company) =>
                  Genre(name: company['name'].toString(), genreId: Genre.noId),
            )
            .toList();

    final runtime = data['episodeRuntime'];

    return MetaEiga(
      name: _title(data),
      originalName:
          data['japanese']?.toString() ?? data['romaji']?.toString(),
      image: _image(pictures?['avatar'] ?? pictures?['banner']),
      poster: _image(pictures?['banner'] ?? pictures?['avatar']),
      description: (data['summary'] ?? '').toString(),
      rate: (data['tmdbScore'] as num?)?.toDouble(),
      duration: runtime is num ? '${runtime.toInt()} dk' : null,
      yearOf: _yearOf(data),
      seasons: seasons,
      genres: _genres(data),
      quality: data['is4K'] == true ? '4K' : 'HD',
      studios: studios,
      language: data['isDubbed'] == true ? 'Dublaj + Altyazılı' : 'Altyazılı',
      status:
          data['inProduction'] == true
              ? StatusEnum.ongoing
              : StatusEnum.completed,
    );
  }

  @override
  getEpisodes(String eigaId) async {
    final slug = _slug(eigaId);
    final season = await _seasonNumber(eigaId);

    List<Map> episodesRaw = const [];
    try {
      final seasonData = await _fetchJson('/anime/$slug/season/$season');
      episodesRaw = _extractEpisodes(seasonData);
    } catch (_) {
      episodesRaw = const [];
    }

    // Fallback: derive the episode list from the season's episode_count.
    if (episodesRaw.isEmpty) {
      final detail = await _animeDetail(slug);
      final seasons =
          (detail['seasons'] as List?)?.whereType<Map>().toList() ?? const [];
      final seasonMeta = seasons.firstWhereOrNull(
        (s) => (s['season_number'] as num?)?.toInt() == season,
      );
      final embedded = seasonMeta == null ? null : _extractEpisodes(seasonMeta);
      if (embedded != null && embedded.isNotEmpty) {
        episodesRaw = embedded;
      } else {
        final count =
            (seasonMeta?['episode_count'] ??
                    seasonMeta?['episodes_count'] ??
                    detail['numberOfEpisodes'])
                as num?;
        if (count != null && count > 0) {
          episodesRaw = List.generate(
            count.toInt(),
            (index) => {'episodeNumber': index + 1},
          );
        }
      }
    }

    if (episodesRaw.isEmpty) throw Exception('Bölüm bulunamadı');

    final episodes =
        episodesRaw.indexed.map((entry) {
          final index = entry.$1;
          final episode = entry.$2;
          final number =
              (episode['episodeNumber'] ??
                      episode['episode_number'] ??
                      episode['episode'] ??
                      episode['number'] ??
                      (index + 1))
                  as num;
          final order = number.toInt();
          return EigaEpisode(
            name: (episode['name'] ?? 'Bölüm $order').toString(),
            episodeId: order.toString(),
            image:
                episode['avatar'] == null
                    ? null
                    : _image(episode['avatar']),
            order: order,
          );
        }).toList();

    return EigaEpisodes(episodes: episodes);
  }

  @override
  getServers({required eigaId, required episode}) async {
    final slug = _slug(eigaId);
    final season = await _seasonNumber(eigaId);
    final episodeData = await _episodeDetail(slug, season, episode.episodeId);

    final files = _filesOf(episodeData);

    final servers =
        files
            .where((file) => _fileIdentifier(file) != null)
            .map((file) {
              final resolution = _resolution(
                file['rawResolution'] ?? file['resolution'],
              );
              final fansub = _fansubName(file);
              final name = [
                resolution > 0 ? '${resolution}p' : 'Kaynak',
                if (fansub != null) fansub,
              ].join(' • ');

              return (
                resolution: resolution,
                server: ServerSource(
                  name: name,
                  serverId: _fileIdentifier(file)!,
                ),
              );
            })
            .toList()
          ..sort((a, b) => b.resolution.compareTo(a.resolution));

    return servers.map((entry) => entry.server).toList();
  }

  @override
  getSource({required eigaId, required episode, server}) async {
    final slug = _slug(eigaId);
    final season = await _seasonNumber(eigaId);
    final episodeData = await _episodeDetail(slug, season, episode.episodeId);

    final files = _filesOf(episodeData);
    if (files.isEmpty) throw Exception('Video kaynağı bulunamadı');

    Map? file;
    if (server != null) {
      file = files.firstWhereOrNull(
        (f) => _fileIdentifier(f) == server.serverId,
      );
    }
    file ??= files.reduce(
      (best, current) =>
          _resolution(current['rawResolution'] ?? current['resolution']) >
                  _resolution(best['rawResolution'] ?? best['resolution'])
              ? current
              : best,
    );

    final fileId = _fileIdentifier(file);
    if (fileId == null) throw Exception('Video kimliği bulunamadı');

    return SourceVideo(
      src: _buildCdnUrl(slug, season, fileId),
      type: 'mp4',
      headers: _headers,
      extra: jsonEncode(episodeData['skiptimes'] ?? {}),
    );
  }

  @override
  getOpeningEnding(context) async {
    final extra = context.source.extra;
    if (extra == null || extra.isEmpty) return null;

    final skiptimes = jsonDecode(extra);
    if (skiptimes is! Map) return null;

    DurationRange? range(dynamic data) {
      if (data is! Map) return null;
      final start = data['start'];
      final end = data['end'];
      if (start is! num || end is! num || start == end) return null;
      return DurationRange(
        start: Duration(seconds: start.floor()),
        end: Duration(seconds: end.floor()),
      );
    }

    final opening = range(skiptimes['intro']);
    final ending = range(skiptimes['outro']);
    if (opening == null && ending == null) return null;

    return OpeningEnding(opening: opening, ending: ending);
  }

  @override
  getSuggest({required metaEiga, required eigaId, page}) async {
    return <Eiga>[];
  }
}
