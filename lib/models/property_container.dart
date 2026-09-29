enum PropertyType { apartment, house, villa, commercial, townhouse, travelersuite, campsite }
enum ListingType { sale, rent, short_term }
enum PriceType { monthly, nightly }
enum EscrowStatus { available, pending_escrow, sold, disputed }
enum TrustStatus { standard, verified, titan_trust, limited }

class PropertyCore {
  final String id;
  final String listerId;
  final String? agentId;
  final String title;
  final String description;
  final PropertyType propertyType;
  final ListingType listingType;
  final int bedrooms;
  final int bathrooms;
  final int sizeSqft;
  final String address;
  final String city;
  final String district;
  final String country;
  final double latitude;
  final double longitude;
  final List<String> images;
  final List<String> bathroomImageUrls;
  final String? authorityStampUrl;
  final String? lc1LetterUrl;
  final String? agentPhone;
  final String? agentWhatsapp;
  final String? agentGoogleMeet;
  final String? agentName;
  final String? agentAvatar;
  final int? agentTrustScore;

  PropertyCore({
    required this.id,
    required this.listerId,
    this.agentId,
    required this.title,
    required this.description,
    required this.propertyType,
    required this.listingType,
    required this.bedrooms,
    required this.bathrooms,
    required this.sizeSqft,
    required this.address,
    required this.city,
    required this.district,
    required this.country,
    required this.latitude,
    required this.longitude,
    required this.images,
    required this.bathroomImageUrls,
    this.authorityStampUrl,
    this.lc1LetterUrl,
    this.agentPhone,
    this.agentWhatsapp,
    this.agentGoogleMeet,
    this.agentName,
    this.agentAvatar,
    this.agentTrustScore,
  });

  factory PropertyCore.fromJson(Map<String, dynamic> json) {
    // Agent profile may be embedded as a nested map by smooth-action join
    final agentProfile = json['agent_profile'] as Map<String, dynamic>?;
    return PropertyCore(
      id: json['id'],
      listerId: json['lister_id'],
      agentId: json['agent_id'],
      title: json['title'] ?? '',
      description: json['description'] ?? '',
      propertyType: json['property_type'] != null 
          ? PropertyType.values.byName(json['property_type']) 
          : PropertyType.apartment,
      listingType: json['listing_type'] != null 
          ? ListingType.values.byName(json['listing_type']) 
          : ListingType.rent,
      bedrooms: json['bedrooms'] ?? 0,
      bathrooms: json['bathrooms'] ?? 0,
      sizeSqft: json['size_sqft'] ?? 0,
      address: json['address'] ?? '',
      city: json['city'] ?? '',
      district: json['district'] ?? '',
      country: json['country'] ?? '',
      latitude: (json['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (json['longitude'] as num?)?.toDouble() ?? 0.0,
      images: List<String>.from(json['images'] ?? []),
      bathroomImageUrls: List<String>.from(json['bathroom_image_urls'] ?? []),
      authorityStampUrl: json['authority_stamp_url'],
      lc1LetterUrl: json['lc1_letter_url'],
      agentPhone: json['agent_phone'],
      agentWhatsapp: json['agent_whatsapp'],
      agentGoogleMeet: json['agent_google_meet'],
      agentName: agentProfile?['full_name']?.toString()
          ?? agentProfile?['display_name']?.toString()
          ?? json['agent_name']?.toString(),
      agentAvatar: agentProfile?['avatar_url']?.toString()
          ?? json['agent_avatar']?.toString(),
      agentTrustScore: (agentProfile?['trust_score'] as num?)?.toInt()
          ?? (json['agent_trust_score'] as num?)?.toInt(),
    );
  }
}

class PropertyFinancial {
  final int price;
  final PriceType priceType;
  final int unlockCost;
  final int escrowDeposit;
  final bool isVerified;
  final TrustStatus trustStatus;
  final int verificationScore;
  final double? aiRelevanceScore;

  PropertyFinancial({
    required this.price,
    required this.priceType,
    required this.unlockCost,
    required this.escrowDeposit,
    required this.isVerified,
    required this.trustStatus,
    required this.verificationScore,
    this.aiRelevanceScore,
  });

  factory PropertyFinancial.fromJson(Map<String, dynamic> json) {
    return PropertyFinancial(
      price: json['price'] ?? 0,
      priceType: PriceType.values.byName(json['price_type'] ?? 'monthly'),
      unlockCost: json['unlock_cost']?.toInt() ?? 0,
      escrowDeposit: json['escrow_deposit']?.toInt() ?? 0,
      isVerified: json['is_verified'] ?? false,
      trustStatus: TrustStatus.values.byName(json['trust_status'] ?? 'standard'),
      verificationScore: json['verification_score'] ?? 0,
      aiRelevanceScore: (json['ai_relevance_score'] as num?)?.toDouble(),
    );
  }
}

class PropertyEscrowState {
  EscrowStatus status;
  final int viewsCount;
  final int unlocksCount;
  final int reservationsCount;
  final bool isHoneypot;
  final DateTime? expiresAt;

  PropertyEscrowState({
    required this.status,
    required this.viewsCount,
    required this.unlocksCount,
    required this.reservationsCount,
    required this.isHoneypot,
    this.expiresAt,
  });

  factory PropertyEscrowState.fromJson(Map<String, dynamic> json) {
    return PropertyEscrowState(
      status: EscrowStatus.values.byName(json['escrow_status'] ?? 'available'),
      viewsCount: json['views_count'] ?? 0,
      unlocksCount: json['unlocks_count'] ?? 0,
      reservationsCount: json['reservations_count'] ?? 0,
      isHoneypot: json['is_honeypot'] ?? false,
      expiresAt: json['escrow_expires_at'] != null ? DateTime.parse(json['escrow_expires_at']) : null,
    );
  }
}

class PropertyShadowLogic {
  final String? umemeMeterNumber;
  final String? nwscCustomerNumber;
  final String? landTitleBlock;
  final String? landTitlePlot;
  final String? lc1ChairmanName;
  final DateTime? lc1StampDate;
  final bool isPhysicallyVerified;
  final double? gpsLatitude;
  final double? gpsLongitude;
  final double? gpsDistanceMeters;
  final bool isUnlockedByCurrentUser;

  PropertyShadowLogic({
    this.umemeMeterNumber,
    this.nwscCustomerNumber,
    this.landTitleBlock,
    this.landTitlePlot,
    this.lc1ChairmanName,
    this.lc1StampDate,
    required this.isPhysicallyVerified,
    this.gpsLatitude,
    this.gpsLongitude,
    this.gpsDistanceMeters,
    this.isUnlockedByCurrentUser = false,
  });

  factory PropertyShadowLogic.fromJson(Map<String, dynamic> json) {
    return PropertyShadowLogic(
      umemeMeterNumber: json['umeme_meter_number'],
      nwscCustomerNumber: json['nwsc_customer_number'],
      landTitleBlock: json['land_title_block'],
      landTitlePlot: json['land_title_plot'],
      lc1ChairmanName: json['lc1_chairman_name'],
      lc1StampDate: json['lc1_stamp_date'] != null ? DateTime.parse(json['lc1_stamp_date']) : null,
      isPhysicallyVerified: json['is_physically_verified'] ?? false,
      gpsLatitude: (json['gps_latitude'] as num?)?.toDouble(),
      gpsLongitude: (json['gps_longitude'] as num?)?.toDouble(),
      gpsDistanceMeters: (json['gps_distance_meters'] as num?)?.toDouble(),
      isUnlockedByCurrentUser: json['is_unlocked_by_user'] ?? false,
    );
  }
}

class PropertyContainer {
  final PropertyCore core;
  final PropertyFinancial financial;
  final PropertyEscrowState escrow;
  final PropertyShadowLogic shadow;

  PropertyContainer({
    required this.core,
    required this.financial,
    required this.escrow,
    required this.shadow,
  });

  factory PropertyContainer.fromJson(Map<String, dynamic> json) {
    return PropertyContainer(
      core: PropertyCore.fromJson(json),
      financial: PropertyFinancial.fromJson(json),
      escrow: PropertyEscrowState.fromJson(json),
      shadow: PropertyShadowLogic.fromJson(json),
    );
  }
}
