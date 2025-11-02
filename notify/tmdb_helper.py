"""
TMDB API Helper Module for Movie Metadata Enrichment
Fetches movie metadata from The Movie Database (TMDB) API
"""
import os
import re
import requests
from collections import OrderedDict


# Bounded LRU cache implementation
class BoundedDict(OrderedDict):
    """LRU cache with maximum size limit"""
    def __init__(self, max_size):
        super().__init__()
        self.max_size = max_size

    def __getitem__(self, key):
        # Move to end on access (LRU behavior)
        value = super().__getitem__(key)
        self.move_to_end(key)
        return value

    def __setitem__(self, key, value):
        if key in self:
            # Move to end (mark as recently used)
            del self[key]
        super().__setitem__(key, value)
        # Evict oldest if over limit
        while len(self) > self.max_size:
            oldest = next(iter(self))
            del self[oldest]


# Configuration
TMDB_API_KEY = os.environ.get('TMDB_API_KEY', '')
TMDB_ENABLED = os.environ.get('TMDB_ENABLED', '1') in ('1', 'true', 'True', 'yes', 'YES')
TMDB_CACHE_MAX_SIZE = int(os.environ.get('TMDB_CACHE_MAX_SIZE', '500'))
TMDB_API_BASE = 'https://api.themoviedb.org/3'
TMDB_TIMEOUT = int(os.environ.get('TMDB_TIMEOUT', '3'))  # Reduced from 5 to 3 seconds

# Global cache
_tmdb_cache = BoundedDict(TMDB_CACHE_MAX_SIZE)


def parse_movie_title_year(program_name, filepath=None):
    """
    Extract movie title and year from program name or filepath.

    Patterns:
    - "Bad Boys II - 2003" → ("Bad Boys II", 2003)
    - "Bad_Boys_II_-_2003--uuid.mkv" → ("Bad Boys II", 2003)
    - "4K__Title_-_2025--uuid.mkv" → ("Title", 2025)

    Returns:
        tuple: (title, year) or (title, None) if year not found
    """
    title = None
    year = None

    # Try program name first (e.g., "Bad Boys II - 2003")
    if program_name:
        # Match pattern: "Title - YYYY" or "Title (YYYY)"
        match = re.search(r'^(.+?)\s*[-–]\s*(\d{4})$', program_name)
        if match:
            title = match.group(1).strip()
            # Strip channel/quality prefixes like "4K:", "HD:", "EN:", etc.
            title = re.sub(r'^(4K|HD|UHD|EN|US|UK):\s*', '', title, flags=re.IGNORECASE)
            year = int(match.group(2))
            return (title, year)

        # Try parentheses pattern
        match = re.search(r'^(.+?)\s*\((\d{4})\)$', program_name)
        if match:
            title = match.group(1).strip()
            # Strip channel/quality prefixes like "4K:", "HD:", "EN:", etc.
            title = re.sub(r'^(4K|HD|UHD|EN|US|UK):\s*', '', title, flags=re.IGNORECASE)
            year = int(match.group(2))
            return (title, year)

        # Use program name as-is if no year found
        title = program_name.strip()
        # Strip channel/quality prefixes from fallback title as well
        title = re.sub(r'^(4K|HD|UHD|EN|US|UK):\s*', '', title, flags=re.IGNORECASE)

    # Try filepath if program name didn't yield results
    if filepath and not year:
        # Extract filename from path
        filename = os.path.basename(filepath)

        # Remove extension
        filename = re.sub(r'\.(mkv|mp4|avi|m4v|ts)$', '', filename, flags=re.IGNORECASE)

        # Remove UUID at end (e.g., --ba016871-8faa-430c-8cba-a0263ea1ae59)
        filename = re.sub(r'--[a-f0-9-]{30,}$', '', filename)

        # Match pattern: Title_-_YYYY
        match = re.search(r'^(.+?)_-_(\d{4})$', filename)
        if match:
            # Convert underscores to spaces, clean up prefixes like "4K__", "EN_-_"
            title_raw = match.group(1)
            title_raw = re.sub(r'^(4K__|EN_-_|HD__|UHD__)', '', title_raw)
            title = title_raw.replace('_', ' ').strip()
            year = int(match.group(2))
            return (title, year)

    return (title, year)


def search_tmdb_movie(title, year=None):
    """
    Search TMDB for movie by title and optionally year.

    Args:
        title (str): Movie title
        year (int, optional): Release year

    Returns:
        dict: Movie metadata or None if not found
              {
                  'tmdb_id': int,
                  'title': str,
                  'overview': str,
                  'genres': [str],
                  'vote_average': float,
                  'vote_count': int,
                  'release_date': str,
                  'poster_path': str,
                  'backdrop_path': str
              }
    """
    if not TMDB_ENABLED or not TMDB_API_KEY or not title:
        return None

    # Check cache
    cache_key = f"{title}:{year}" if year else title
    if cache_key in _tmdb_cache:
        return _tmdb_cache[cache_key]

    # Search TMDB
    try:
        params = {
            'api_key': TMDB_API_KEY,
            'query': title,
            'language': 'en-US',
        }
        if year:
            params['year'] = year

        response = requests.get(
            f'{TMDB_API_BASE}/search/movie',
            params=params,
            timeout=TMDB_TIMEOUT
        )

        if not response.ok:
            print(f"[tmdb] Search failed: HTTP {response.status_code}")
            return None

        data = response.json()
        results = data.get('results', [])

        if not results:
            print(f"[tmdb] No results found for '{title}' ({year})")
            _tmdb_cache[cache_key] = None
            return None

        # Take first result (most relevant)
        movie = results[0]

        # Get genre names
        genre_ids = movie.get('genre_ids', [])
        genres = get_genre_names(genre_ids)

        metadata = {
            'tmdb_id': movie.get('id'),
            'title': movie.get('title'),
            'original_title': movie.get('original_title'),
            'overview': movie.get('overview', ''),
            'genres': genres,
            'vote_average': movie.get('vote_average'),
            'vote_count': movie.get('vote_count'),
            'release_date': movie.get('release_date'),
            'poster_path': movie.get('poster_path'),
            'backdrop_path': movie.get('backdrop_path'),
            'popularity': movie.get('popularity'),
        }

        # Cache result
        _tmdb_cache[cache_key] = metadata
        print(f"[tmdb] Found: {metadata['title']} ({metadata.get('release_date', 'unknown')[:4]})")

        return metadata

    except Exception as e:
        print(f"[tmdb] Error searching for '{title}': {e}")
        return None


# TMDB Genre ID to Name mapping (as of 2024)
# Includes both movie and TV series genres
GENRE_MAP = {
    # Movie genres
    28: 'Action',
    12: 'Adventure',
    16: 'Animation',
    35: 'Comedy',
    80: 'Crime',
    99: 'Documentary',
    18: 'Drama',
    10751: 'Family',
    14: 'Fantasy',
    36: 'History',
    27: 'Horror',
    10402: 'Music',
    9648: 'Mystery',
    10749: 'Romance',
    878: 'Science Fiction',
    10770: 'TV Movie',
    53: 'Thriller',
    10752: 'War',
    37: 'Western',
    # TV-specific genres
    10759: 'Action & Adventure',
    10762: 'Kids',
    10763: 'News',
    10764: 'Reality',
    10765: 'Sci-Fi & Fantasy',
    10766: 'Soap',
    10767: 'Talk',
    10768: 'War & Politics'
}


def get_genre_names(genre_ids):
    """Convert genre IDs to genre names"""
    if not genre_ids:
        return []
    return [GENRE_MAP.get(gid, f'Unknown({gid})') for gid in genre_ids]


def parse_series_title_year(program_name):
    """
    Extract TV series title and year from program name.

    Patterns:
    - "Tulsa King (2022)" → ("Tulsa King", 2022)
    - "Breaking Bad" → ("Breaking Bad", None)

    Returns:
        tuple: (title, year) or (title, None) if year not found
    """
    title = None
    year = None

    if program_name:
        # Match pattern: "Title (YYYY)"
        match = re.search(r'^(.+?)\s*\((\d{4})\)$', program_name)
        if match:
            title = match.group(1).strip()
            year = int(match.group(2))
            return (title, year)

        # Use program name as-is if no year found
        title = program_name.strip()

    return (title, year)


def search_tmdb_tv(title, year=None):
    """
    Search TMDB for TV series by title and optionally year.

    Args:
        title (str): TV series title
        year (int, optional): First air year

    Returns:
        dict: TV series metadata or None if not found
              {
                  'tmdb_id': int,
                  'name': str,
                  'overview': str,
                  'genres': [str],
                  'vote_average': float,
                  'vote_count': int,
                  'first_air_date': str,
                  'poster_path': str,
                  'backdrop_path': str
              }
    """
    if not TMDB_ENABLED or not TMDB_API_KEY or not title:
        return None

    # Check cache
    cache_key = f"tv:{title}:{year}" if year else f"tv:{title}"
    if cache_key in _tmdb_cache:
        return _tmdb_cache[cache_key]

    # Search TMDB
    try:
        params = {
            'api_key': TMDB_API_KEY,
            'query': title,
            'language': 'en-US',
        }
        if year:
            params['first_air_date_year'] = year

        response = requests.get(
            f'{TMDB_API_BASE}/search/tv',
            params=params,
            timeout=TMDB_TIMEOUT
        )

        if not response.ok:
            print(f"[tmdb] TV search failed: HTTP {response.status_code}")
            return None

        data = response.json()
        results = data.get('results', [])

        if not results:
            print(f"[tmdb] No TV results found for '{title}' ({year})")
            _tmdb_cache[cache_key] = None
            return None

        # Take first result (most relevant)
        show = results[0]

        # Get genre names
        genre_ids = show.get('genre_ids', [])
        genres = get_genre_names(genre_ids)

        metadata = {
            'tmdb_id': show.get('id'),
            'name': show.get('name'),
            'original_name': show.get('original_name'),
            'overview': show.get('overview', ''),
            'genres': genres,
            'vote_average': show.get('vote_average'),
            'vote_count': show.get('vote_count'),
            'first_air_date': show.get('first_air_date'),
            'poster_path': show.get('poster_path'),
            'backdrop_path': show.get('backdrop_path'),
            'popularity': show.get('popularity'),
        }

        # Cache result
        _tmdb_cache[cache_key] = metadata
        print(f"[tmdb] Found TV: {metadata['name']} ({metadata.get('first_air_date', 'unknown')[:4]})")

        return metadata

    except Exception as e:
        print(f"[tmdb] Error searching TV for '{title}': {e}")
        return None


def enrich_series_metadata(program_name):
    """
    Main entry point: Parse TV series info and fetch TMDB metadata.

    Args:
        program_name (str): TV series program name (e.g., "Tulsa King (2022)")

    Returns:
        dict: TMDB metadata or None if not found
    """
    if not TMDB_ENABLED or not TMDB_API_KEY:
        return None

    title, year = parse_series_title_year(program_name)

    if not title:
        print(f"[tmdb] Could not parse TV title from: {program_name}")
        return None

    print(f"[tmdb] Parsed TV: '{title}' ({year or 'no year'})")
    return search_tmdb_tv(title, year)


def enrich_movie_metadata(program_name, filepath=None):
    """
    Main entry point: Parse movie info and fetch TMDB metadata.

    Args:
        program_name (str): Movie program name (e.g., "Bad Boys II - 2003")
        filepath (str, optional): Full file path

    Returns:
        dict: TMDB metadata or None if not found
    """
    if not TMDB_ENABLED or not TMDB_API_KEY:
        return None

    title, year = parse_movie_title_year(program_name, filepath)

    if not title:
        print(f"[tmdb] Could not parse title from: {program_name}")
        return None

    print(f"[tmdb] Parsed: '{title}' ({year or 'no year'})")
    return search_tmdb_movie(title, year)
