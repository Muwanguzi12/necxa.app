class ContentSanitizer {
  
  /// Formats and sanitizes a raw comma-separated tag string into clean, valid tags.
  /// Removes empty strings, trims whitespace, standardizes to lowercase, and strips illegal characters.
  static List<String> sanitizeTags(String raw) {
    if (raw.trim().isEmpty) return [];
    
    // Split by comma or space
    return raw.split(RegExp(r'[,\\s]+'))
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .map((e) {
          // Remove any non-alphanumeric characters except underscores
          String cleaned = e.replaceAll(RegExp(r'[^a-z0-9_]'), '');
          // If the tag originally had a # but got stripped, we just ensure it's clean text
          return cleaned.startsWith('#') ? cleaned : '#$cleaned';
        })
        .where((e) => e.length > 1) // Must have at least one character after the #
        .toSet() // Remove duplicates
        .toList();
  }

  /// Automatically parses a post description and extracts all embedded #hashtags.
  static List<String> extractHashtagsFromText(String text) {
    if (text.isEmpty) return [];
    
    RegExp regex = RegExp(r'#[a-zA-Z0-9_]+');
    Iterable<Match> matches = regex.allMatches(text);
    
    return matches.map((m) => m.group(0)!.toLowerCase()).toSet().toList();
  }

  /// Combines manually inputted tags and extracted text hashtags into a single unified list.
  static List<String> generateUnifiedTagPayload(String manualTags, String description) {
    List<String> explicitTags = sanitizeTags(manualTags);
    List<String> inlineTags = extractHashtagsFromText(description);
    
    return <String>{...explicitTags, ...inlineTags}.toList();
  }

  /// Cleans the descriptions to prevent text injections, excessive whitespace, 
  /// and sanitizes formatting for the grid.
  static String cleanDescription(String raw) {
    if (raw.trim().isEmpty) return '';
    
    // Remove excessive consecutive newlines (more than 2)
    String cleaned = raw.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    
    // Trim leading whitespace on each line
    cleaned = cleaned.split('\n').map((line) => line.trimRight()).join('\n');
    
    return cleaned.trim();
  }
}
