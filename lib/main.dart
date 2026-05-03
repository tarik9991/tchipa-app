import 'dart:math';
import 'dart:async';
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:local_auth/local_auth.dart';
import 'package:webview_flutter/webview_flutter.dart';

// ============================================
// CONFIGURATION
// ============================================
const String kVpsBase       = 'http://76.13.255.239:3000';
const double kExchangeRate  = 242.0;
const double kActivationFee = 7.0;
const String kAgentTelegram = 'https://t.me/c/3983752002/1';

// ============================================
// VCC CARD MODEL
// ============================================
class VccCard {
  final String? cardId;
  final String? cardNumber;
  final String? expiry;
  final String? cvv;
  final String? holderName;
  final double balance;
  final bool isActivated;
  final String? redeemId;
  final String? redeemLink;

  const VccCard({
    this.cardId,
    this.cardNumber,
    this.expiry,
    this.cvv,
    this.holderName,
    this.balance = 0.0,
    this.isActivated = false,
    this.redeemId,
    this.redeemLink,
  });

  bool get hasCard =>
      (cardNumber != null && cardNumber!.isNotEmpty) || redeemLink != null;

  String get maskedNumber {
    if (cardNumber == null || cardNumber!.isEmpty) return '•••• •••• •••• ••••';
    final n = cardNumber!.replaceAll(RegExp(r'[\s\-]'), '');
    if (n.length != 16) return cardNumber!;
    return '•••• •••• •••• ${n.substring(12)}';
  }

  String get formattedNumber {
    if (cardNumber == null || cardNumber!.isEmpty) return '•••• •••• •••• ••••';
    final n = cardNumber!.replaceAll(RegExp(r'[\s\-]'), '');
    if (n.length != 16) return cardNumber!;
    return '${n.substring(0, 4)} ${n.substring(4, 8)} '
        '${n.substring(8, 12)} ${n.substring(12)}';
  }

  Map<String, dynamic> toJson() => {
        'cardId': cardId,
        'cardNumber': cardNumber,
        'expiry': expiry,
        'cvv': cvv,
        'holderName': holderName,
        'balance': balance,
        'isActivated': isActivated,
        'redeemId': redeemId,
        'redeemLink': redeemLink,
      };

  factory VccCard.fromJson(Map<String, dynamic> j) => VccCard(
        cardId: j['cardId']?.toString() ??
            j['card_id']?.toString() ??
            j['id']?.toString(),
        cardNumber: j['cardNumber']?.toString() ??
            j['card_number']?.toString() ??
            j['number']?.toString(),
        expiry: j['expiry']?.toString() ??
            j['expiration']?.toString() ??
            j['exp']?.toString(),
        cvv: j['cvv']?.toString() ?? j['cvc']?.toString(),
        holderName: j['holderName']?.toString() ??
            j['holder_name']?.toString() ??
            j['name']?.toString(),
        balance: (j['balance'] as num?)?.toDouble() ?? 0.0,
        isActivated: j['isActivated'] as bool? ??
            j['is_activated'] as bool? ??
            false,
        redeemId: j['redeemId']?.toString(),
        redeemLink: j['redeemLink']?.toString(),
      );

  VccCard copyWith({
    String? cardId,
    String? cardNumber,
    String? expiry,
    String? cvv,
    String? holderName,
    double? balance,
    bool? isActivated,
    String? redeemId,
    String? redeemLink,
  }) =>
      VccCard(
        cardId: cardId ?? this.cardId,
        cardNumber: cardNumber ?? this.cardNumber,
        expiry: expiry ?? this.expiry,
        cvv: cvv ?? this.cvv,
        holderName: holderName ?? this.holderName,
        balance: balance ?? this.balance,
        isActivated: isActivated ?? this.isActivated,
        redeemId: redeemId ?? this.redeemId,
        redeemLink: redeemLink ?? this.redeemLink,
      );

  static Future<VccCard?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('vcc_card');
    if (raw == null) return null;
    try {
      return VccCard.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('vcc_card', jsonEncode(toJson()));
  }

  static Future<void> remove() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('vcc_card');
  }
}

// ============================================
// VCC ORDER (pending crypto payment)
// ============================================
class VccOrder {
  final String redeemId;
  final String cryptoAddress;
  final String amountUsdt;
  final String? qrCodeBase64;
  final double cardValue;
  final String cardType;

  const VccOrder({
    required this.redeemId,
    required this.cryptoAddress,
    required this.amountUsdt,
    required this.cardValue,
    required this.cardType,
    this.qrCodeBase64,
  });

  factory VccOrder.fromJson(Map<String, dynamic> j) => VccOrder(
        redeemId:      j['redeemId']?.toString() ?? '',
        cryptoAddress: j['cryptoAddress']?.toString() ?? '',
        amountUsdt:    j['amountUsdt']?.toString() ?? '0',
        cardValue:     (j['cardValue'] as num?)?.toDouble() ?? 0.0,
        cardType:      j['cardType']?.toString() ?? 'mastercard',
        qrCodeBase64:  j['qrCode']?.toString(),
      );
}

// ============================================
// TRANSACTION MODEL
// ============================================
class VccTx {
  final String type;
  final double amount;
  final String label;
  final DateTime date;
  final bool isDebit;

  const VccTx({
    required this.type,
    required this.amount,
    required this.label,
    required this.date,
    this.isDebit = false,
  });

  Map<String, dynamic> toJson() => {
        'type': type,
        'amount': amount,
        'label': label,
        'date': date.toIso8601String(),
        'isDebit': isDebit,
      };

  factory VccTx.fromJson(Map<String, dynamic> j) => VccTx(
        type: j['type'] as String? ?? 'payment',
        amount: (j['amount'] as num?)?.toDouble() ?? 0.0,
        label: j['label'] as String? ?? '',
        date: DateTime.tryParse(j['date'] as String? ?? '') ??
            DateTime.now(),
        isDebit: j['isDebit'] as bool? ?? false,
      );

  static Future<List<VccTx>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList('vcc_txs') ?? [])
        .map((s) {
          try {
            return VccTx.fromJson(
                jsonDecode(s) as Map<String, dynamic>);
          } catch (_) {
            return null;
          }
        })
        .whereType<VccTx>()
        .toList();
  }

  static Future<void> add(VccTx tx) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('vcc_txs') ?? [];
    list.insert(0, jsonEncode(tx.toJson()));
    await prefs.setStringList('vcc_txs', list.take(100).toList());
  }
}

// ============================================
// USER PROFILE
// ============================================
class UserProfile {
  static String name = '';
  static String phone = '';
  static String email = '';

  static bool get isEmpty =>
      name.trim().isEmpty || phone.trim().isEmpty;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    name  = prefs.getString('profile_name')  ?? '';
    phone = prefs.getString('profile_phone') ?? '';
    email = prefs.getString('profile_email') ?? '';
  }

  static Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('profile_name',  name);
    await prefs.setString('profile_phone', phone);
    await prefs.setString('profile_email', email);
  }
}

// ============================================
// PAYGATE SERVICE
// ============================================
class PayGateService {
  static Future<VccOrder> createVccOrder({
    required double amount,
    String cardType = 'mastercard',
    String? holderName,
    String? phone,
  }) async {
    final resp = await http
        .post(
          Uri.parse('$kVpsBase/paygate/create-vcc'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'amount': amount,
            'cardType': cardType,
            'holderName': holderName,
            'phone': phone,
          }),
        )
        .timeout(const Duration(seconds: 35));
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode == 200 || resp.statusCode == 201) {
      return VccOrder.fromJson(body);
    }
    throw Exception(body['error'] ?? 'Erreur PayGate (${resp.statusCode})');
  }

  static Future<Map<String, dynamic>> checkVccStatus(String redeemId) async {
    final resp = await http
        .get(Uri.parse(
            '$kVpsBase/paygate/check-status?redeem_id=${Uri.encodeComponent(redeemId)}'))
        .timeout(const Duration(seconds: 20));
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode == 200) return body;
    throw Exception(body['error'] ?? 'Erreur statut (${resp.statusCode})');
  }

  static Future<double> fetchBalance(String cardId) async => 0.0;
}

// ============================================
// MAIN
// ============================================
// ============================================
// APP SETTINGS (theme + language)
// ============================================
final ValueNotifier<bool>   darkModeNotifier = ValueNotifier(true);
final ValueNotifier<String> langNotifier     = ValueNotifier('fr');

class AppSettings {
  static const _kDark = 'dark_mode';
  static const _kLang = 'app_lang';

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    darkModeNotifier.value = p.getBool(_kDark) ?? true;
    langNotifier.value     = p.getString(_kLang) ?? 'fr';
    AppColors.update(darkModeNotifier.value);
  }

  static Future<void> setDark(bool v) async {
    darkModeNotifier.value = v;
    AppColors.update(v);
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kDark, v);
  }

  static Future<void> setLang(String v) async {
    langNotifier.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kLang, v);
  }
}

// ============================================
// SEMANTIC COLORS (theme-aware)
// ============================================
class AppColors {
  static Color bg       = const Color(0xFF0D1117);
  static Color surface  = const Color(0xFF0F1923);
  static Color card     = const Color(0xFF1A2332);
  static Color text     = Colors.white;
  static Color textSub  = Colors.white60;
  static Color textDim  = Colors.white38;
  static Color border   = const Color(0xFF1A2332);
  // Adaptive helpers — always readable on bg/surface/card
  static Color label    = Colors.white;       // primary label on bg
  static Color sublabel = Colors.white60;     // secondary label
  static Color hint     = Colors.white38;     // placeholder / hint
  static Color inputFg  = Colors.white;       // text-field input text
  static Color navUnsel = Colors.white38;     // unselected nav icon/label
  static bool  isDark   = true;

  static void update(bool dark) {
    isDark = dark;
    if (dark) {
      bg       = const Color(0xFF0D1117);
      surface  = const Color(0xFF0F1923);
      card     = const Color(0xFF1A2332);
      text     = Colors.white;
      textSub  = Colors.white60;
      textDim  = Colors.white38;
      border   = const Color(0xFF2A3347);
      label    = Colors.white;
      sublabel = Colors.white60;
      hint     = Colors.white38;
      inputFg  = Colors.white;
      navUnsel = Colors.white38;
    } else {
      bg       = const Color(0xFFF0F5FF);
      surface  = const Color(0xFFFFFFFF);
      card     = const Color(0xFFEAF0FB);
      text     = const Color(0xFF0D1117);
      textSub  = const Color(0xFF334155);
      textDim  = const Color(0xFF64748B);
      border   = const Color(0xFFD1DCF0);
      label    = const Color(0xFF0D1117);
      sublabel = const Color(0xFF334155);
      hint     = const Color(0xFF94A3B8);
      inputFg  = const Color(0xFF0D1117);
      navUnsel = const Color(0xFF64748B);
    }
  }
}

// ============================================
// TRANSLATIONS (FR / AR)
// ============================================
class _L {
  final String activate;
  final String activateSubtitle;
  final String chooseAmount;
  final String payDirectly;
  final String sendExactly;
  final String usdtPolygonOnly;
  final String exactAmount;
  final String usdtAddress;
  final String addressCopied;
  final String polygonWarning;
  final String paidVerify;
  final String orderCreated;
  final String newVccCard;
  final String checking;
  final String cardReady;
  final String newCardActivated;
  final String viewCard;
  final String close;
  final String paymentReceived;
  final String paymentNotReceived;
  final String recharge;
  final String createOrder;
  final String myProfile;
  final String saveProfile;
  final String biometric;
  final String biometricSub;
  final String agentMode;
  final String settings;
  final String language;
  final String theme;
  final String lightMode;
  final String darkMode;
  final String french;
  final String arabic;
  final String home;
  final String transactions;
  final String profile;
  final String activate2;
  final String activated;
  final String cardActive;
  final String activateCard;
  final String cardReady2;
  final String cardActivated;
  final String mastercard;
  final String cardNetwork;

  const _L({
    required this.activate,
    required this.activateSubtitle,
    required this.chooseAmount,
    required this.payDirectly,
    required this.sendExactly,
    required this.usdtPolygonOnly,
    required this.exactAmount,
    required this.usdtAddress,
    required this.addressCopied,
    required this.polygonWarning,
    required this.paidVerify,
    required this.orderCreated,
    required this.newVccCard,
    required this.checking,
    required this.cardReady,
    required this.newCardActivated,
    required this.viewCard,
    required this.close,
    required this.paymentReceived,
    required this.paymentNotReceived,
    required this.recharge,
    required this.createOrder,
    required this.myProfile,
    required this.saveProfile,
    required this.biometric,
    required this.biometricSub,
    required this.agentMode,
    required this.settings,
    required this.language,
    required this.theme,
    required this.lightMode,
    required this.darkMode,
    required this.french,
    required this.arabic,
    required this.home,
    required this.transactions,
    required this.profile,
    required this.activate2,
    required this.activated,
    required this.cardActive,
    required this.activateCard,
    required this.cardReady2,
    required this.cardActivated,
    required this.mastercard,
    required this.cardNetwork,
  });
}

const _fr = _L(
  activate: 'Activer ma carte',
  activateSubtitle: 'Paiement direct USDT · Réseau Polygon',
  chooseAmount: 'Choisir le montant de la carte',
  payDirectly: 'Payez directement en USDT sur le réseau Polygon',
  sendExactly: 'Envoyez exactement',
  usdtPolygonOnly: 'USDT sur le réseau Polygon uniquement',
  exactAmount: 'MONTANT EXACT À ENVOYER',
  usdtAddress: 'ADRESSE USDT (POLYGON)',
  addressCopied: 'Adresse copiée',
  polygonWarning: '⚠ Envoyez uniquement sur le réseau Polygon. Tout envoi sur un autre réseau sera perdu.',
  paidVerify: 'J\'ai payé — Vérifier',
  orderCreated: 'Commande créée',
  newVccCard: 'Nouvelle carte VCC',
  checking: 'Vérification du paiement…',
  cardReady: 'Carte prête !',
  newCardActivated: 'Votre nouvelle carte VCC Mastercard est activée.',
  viewCard: 'Voir ma carte',
  close: 'Fermer',
  paymentReceived: 'Paiement reçu — carte en cours d\'émission, revérifiez dans 1 min.',
  paymentNotReceived: 'Paiement non reçu. Vérifiez que vous avez envoyé exactement',
  recharge: 'Nouvelle carte',
  createOrder: 'Créer ma commande',
  myProfile: 'Mon profil',
  saveProfile: 'Enregistrer',
  biometric: 'Protection biométrique',
  biometricSub: 'Empreinte / Face ID au démarrage',
  agentMode: 'Mode Agent',
  settings: 'Paramètres',
  language: 'Langue',
  theme: 'Thème',
  lightMode: 'Mode clair',
  darkMode: 'Mode sombre',
  french: 'Français',
  arabic: 'العربية',
  home: 'Accueil',
  transactions: 'Transactions',
  profile: 'Profil',
  activate2: 'Activer',
  activated: 'Activée',
  cardActive: 'Carte active · Paiements internationaux',
  activateCard: 'Activez votre carte pour commencer',
  cardReady2: 'Carte activée !',
  cardActivated: 'Votre carte VCC Mastercard est prête.',
  mastercard: 'Carte Mastercard',
  cardNetwork: 'réseau Polygon',
);

const _ar = _L(
  activate: 'تفعيل البطاقة',
  activateSubtitle: 'دفع مباشر بـ USDT · شبكة Polygon',
  chooseAmount: 'اختر قيمة البطاقة',
  payDirectly: 'ادفع مباشرةً بـ USDT على شبكة Polygon',
  sendExactly: 'أرسل بالضبط',
  usdtPolygonOnly: 'USDT على شبكة Polygon فقط',
  exactAmount: 'المبلغ الدقيق للإرسال',
  usdtAddress: 'عنوان USDT (Polygon)',
  addressCopied: 'تم نسخ العنوان',
  polygonWarning: '⚠ أرسل فقط على شبكة Polygon. أي إرسال على شبكة أخرى سيُفقد.',
  paidVerify: 'دفعت — تحقق',
  orderCreated: 'تم إنشاء الطلب',
  newVccCard: 'بطاقة VCC جديدة',
  checking: 'جارٍ التحقق من الدفع…',
  cardReady: 'البطاقة جاهزة!',
  newCardActivated: 'بطاقة Mastercard VCC الجديدة مُفعَّلة.',
  viewCard: 'عرض البطاقة',
  close: 'إغلاق',
  paymentReceived: 'تم استلام الدفع — يتم إصدار البطاقة، تحقق خلال دقيقة.',
  paymentNotReceived: 'لم يُستلم الدفع. تأكد من إرسال بالضبط',
  recharge: 'بطاقة جديدة',
  createOrder: 'إنشاء طلب',
  myProfile: 'ملفي الشخصي',
  saveProfile: 'حفظ',
  biometric: 'الحماية البيومترية',
  biometricSub: 'بصمة الإصبع / Face ID عند التشغيل',
  agentMode: 'وضع الوكيل',
  settings: 'الإعدادات',
  language: 'اللغة',
  theme: 'المظهر',
  lightMode: 'المظهر الفاتح',
  darkMode: 'المظهر الداكن',
  french: 'Français',
  arabic: 'العربية',
  home: 'الرئيسية',
  transactions: 'المعاملات',
  profile: 'الملف',
  activate2: 'تفعيل',
  activated: 'مُفعَّلة',
  cardActive: 'بطاقة نشطة · مدفوعات دولية',
  activateCard: 'فعّل بطاقتك للبدء',
  cardReady2: 'تم تفعيل البطاقة!',
  cardActivated: 'بطاقة VCC Mastercard جاهزة.',
  mastercard: 'بطاقة Mastercard',
  cardNetwork: 'شبكة Polygon',
);

_L get L => langNotifier.value == 'ar' ? _ar : _fr;

// ============================================
// APP LOCK (biometric / device credentials)
// ============================================
class AppLock {
  static const _kEnabled = 'app_lock_enabled';

  static Future<bool> isEnabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kEnabled) ?? false;
  }

  static Future<void> setEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kEnabled, v);
  }

  static Future<bool> authenticate(BuildContext context) async {
    final auth = LocalAuthentication();
    try {
      final available = await auth.canCheckBiometrics || await auth.isDeviceSupported();
      if (!available) return true;
      return await auth.authenticate(
        localizedReason: 'Authentifiez-vous pour accéder à Tchipa',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
    } catch (_) {
      return true;
    }
  }
}

// ============================================
// LOCK SCREEN
// ============================================
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  bool _loading = false;
  String? _error;

  Future<void> _tryAuth() async {
    setState(() { _loading = true; _error = null; });
    final ok = await AppLock.authenticate(context);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => const MainScreen(),
          transitionDuration: const Duration(milliseconds: 400),
          transitionsBuilder: (_, anim, __, child) =>
              FadeTransition(opacity: anim, child: child),
        ),
      );
    } else {
      setState(() { _loading = false; _error = 'Authentification refusée'; });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryAuth());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80, height: 80,
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)]),
                borderRadius: BorderRadius.circular(22),
              ),
              child: const Center(
                child: Text('T', style: TextStyle(color: Colors.black, fontSize: 40,
                    fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 32),
            const Text('Tchipa', style: TextStyle(color: Colors.white, fontSize: 28,
                fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Veuillez vous authentifier',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 14)),
            const SizedBox(height: 40),
            if (_loading)
              const CircularProgressIndicator(color: Color(0xFF00D4FF))
            else ...[
              if (_error != null) ...[
                Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
                const SizedBox(height: 16),
              ],
              GestureDetector(
                onTap: _tryAuth,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)]),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.fingerprint_rounded, color: Colors.black, size: 22),
                      SizedBox(width: 10),
                      Text('S\'authentifier', style: TextStyle(color: Colors.black,
                          fontWeight: FontWeight.bold, fontSize: 15)),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await UserProfile.load();
  await AppSettings.load();
  runApp(const TchipaApp());
}

// ============================================
// APP
// ============================================
class TchipaApp extends StatelessWidget {
  const TchipaApp({super.key});

  ThemeData _buildTheme(bool dark) {
    final brightness = dark ? Brightness.dark : Brightness.light;
    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: AppColors.bg,
      primaryColor: const Color(0xFF00D4FF),
      cardColor: AppColors.surface,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF00D4FF),
        brightness: brightness,
        surface: AppColors.surface,
        onSurface: AppColors.text,
      ),
      fontFamily: 'SF Pro Display',
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFF00D4FF)),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        hintStyle: TextStyle(color: AppColors.textDim),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([darkModeNotifier, langNotifier]),
      builder: (_, __) {
        final isAr = langNotifier.value == 'ar';
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Tchipa',
          locale: Locale(langNotifier.value),
          supportedLocales: const [Locale('fr'), Locale('ar')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: _buildTheme(darkModeNotifier.value),
          builder: (ctx, child) => Directionality(
            textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
            child: child ?? const SizedBox.shrink(),
          ),
          home: const SplashScreen(),
        );
      },
    );
  }
}

// ============================================
// SPLASH SCREEN
// ============================================
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late AnimationController _flagCtrl;
  late Animation<double> _flagAnim;
  late AnimationController _imgCtrl;
  late Animation<double> _imgFade;
  late AnimationController _overlayCtrl;
  late Animation<double> _overlayFade;
  late Animation<Offset> _overlaySlide;

  @override
  void initState() {
    super.initState();
    _flagCtrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 4))
      ..repeat();
    _flagAnim =
        Tween<double>(begin: 0, end: 2 * pi).animate(_flagCtrl);

    _imgCtrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 900));
    _imgFade =
        CurvedAnimation(parent: _imgCtrl, curve: Curves.easeIn);

    _overlayCtrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 600));
    _overlayFade = CurvedAnimation(
        parent: _overlayCtrl, curve: Curves.easeIn);
    _overlaySlide = Tween<Offset>(
            begin: const Offset(0, 0.12), end: Offset.zero)
        .animate(CurvedAnimation(
            parent: _overlayCtrl, curve: Curves.easeOut));

    _imgCtrl.forward().then((_) => _overlayCtrl.forward());
    Future.delayed(const Duration(milliseconds: 3200), () async {
      if (!mounted) return;
      final lockEnabled = await AppLock.isEnabled();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(PageRouteBuilder(
        pageBuilder: (_, __, ___) =>
            lockEnabled ? const LockScreen() : const MainScreen(),
        transitionDuration: const Duration(milliseconds: 600),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ));
    });
  }

  @override
  void dispose() {
    _flagCtrl.dispose();
    _imgCtrl.dispose();
    _overlayCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        Center(
          child: FadeTransition(
            opacity: _imgFade,
            child: SizedBox(
              width: 280, height: 280,
              child: Stack(alignment: Alignment.center, children: [
                AnimatedBuilder(
                  animation: _flagCtrl,
                  builder: (_, __) => CustomPaint(
                    size: const Size(280, 280),
                    painter: _ElectricLogoPainter(_flagAnim.value),
                  ),
                ),
                Container(
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Color(0x5900D4FF),
                        blurRadius: 40,
                        spreadRadius: 8,
                      ),
                      BoxShadow(
                        color: Color(0x338B5CF6),
                        blurRadius: 60,
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                  child: ClipOval(
                    child: Image.asset(
                      'assets/nearpay_logo.png',
                      width: 150, height: 150,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
        Positioned(
          left: 0, right: 0, bottom: 0,
          height: size.height * 0.45,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.85),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          left: 0, right: 0, bottom: 52,
          child: SlideTransition(
            position: _overlaySlide,
            child: FadeTransition(
              opacity: _overlayFade,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ShaderMask(
                    shaderCallback: (b) => const LinearGradient(
                      colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
                    ).createShader(b),
                    child: const Text('tchipa',
                        style: TextStyle(
                          fontSize: 42,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: 8,
                        )),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Carte Virtuelle · Paiements Sécurisés',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 13,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: 28, height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                          const Color(0xFF00D4FF)
                              .withValues(alpha: 0.8)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

// ============================================
// MAIN SCREEN (3-tab shell)
// ============================================
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _idx = 0;
  static const _screens = [
    HomeScreen(),
    TransactionsScreen(),
    ProfileScreen(),
  ];

  @override
  void initState() {
    super.initState();
    if (UserProfile.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() => _idx = 2);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Row(children: [
            const Icon(Icons.person_outline, color: Color(0xFF00D4FF)),
            const SizedBox(width: 10),
            Text('Complétez votre profil pour commencer',
                style: TextStyle(color: AppColors.label)),
          ]),
          backgroundColor: AppColors.surface,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
          duration: const Duration(seconds: 3),
        ));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _idx, children: _screens),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          border: Border(
              top: BorderSide(color: AppColors.card, width: 0.5)),
        ),
        child: BottomNavigationBar(
          currentIndex: _idx,
          onTap: (i) => setState(() => _idx = i),
          backgroundColor: AppColors.surface,
          selectedItemColor: const Color(0xFF00D4FF),
          unselectedItemColor: AppColors.navUnsel,
          type: BottomNavigationBarType.fixed,
          selectedFontSize: 11,
          unselectedFontSize: 11,
          items: const [
            BottomNavigationBarItem(
                icon: Icon(Icons.credit_card_rounded),
                label: 'Ma carte'),
            BottomNavigationBarItem(
                icon: Icon(Icons.receipt_long_rounded),
                label: 'Historique'),
            BottomNavigationBarItem(
                icon: Icon(Icons.person_rounded),
                label: 'Profil'),
          ],
        ),
      ),
    );
  }
}

// ============================================
// HOME SCREEN
// ============================================
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin {
  VccCard? _card;
  bool _loading = true;
  bool _showFull = false;
  bool _refreshing = false;

  late AnimationController _shimmerCtrl;
  late AnimationController _glowCtrl;
  late Animation<double> _glowAnim;

  @override
  void initState() {
    super.initState();
    _shimmerCtrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 2))
      ..repeat();
    _glowCtrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1400))
      ..repeat(reverse: true);
    _glowAnim =
        CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOut);
    _load();
  }

  @override
  void dispose() {
    _shimmerCtrl.dispose();
    _glowCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final card = await VccCard.load();
    if (mounted) setState(() { _card = card; _loading = false; });
  }

  Future<void> _refreshBalance() async {
    final card = _card;
    if (card?.isActivated != true || card?.cardId == null) return;
    setState(() => _refreshing = true);
    try {
      final bal = await PayGateService.fetchBalance(card!.cardId!);
      final updated = card.copyWith(balance: bal);
      await updated.save();
      if (mounted) setState(() { _card = updated; _refreshing = false; });
    } catch (e) {
      if (mounted) setState(() => _refreshing = false);
      _showErr(e.toString().replaceAll('Exception: ', ''));
    }
  }

  void _showErr(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: Colors.redAccent,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12)),
    ));
  }

  void _onActivated(VccCard card) {
    setState(() => _card = card);
    VccTx.add(VccTx(
      type: 'activation',
      amount: kActivationFee,
      label: 'Activation carte VCC',
      date: DateTime.now(),
      isDebit: true,
    ));
  }

  void _onRechargeDone(double amount) {
    _load();
    VccTx.add(VccTx(
      type: 'recharge',
      amount: amount,
      label: 'Rechargement carte',
      date: DateTime.now(),
    ));
  }

  void _openActivation() {
    if (UserProfile.isEmpty) {
      _showErr('Complétez votre profil avant d\'activer');
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ActivationSheet(
        onActivated: (card) { Navigator.pop(context); _onActivated(card); },
      ),
    );
  }

  void _openRecharge() {
    final card = _card;
    if (card?.isActivated != true) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _RechargeSheet(
        card: card!,
        onSuccess: (amt) { Navigator.pop(context); _onRechargeDone(amt); },
      ),
    );
  }

  void _openDetails() {
    final card = _card;
    if (card?.isActivated != true) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _CardDetailsSheet(card: card!),
    );
  }

  void _openCardLink() {
    final card = _card;
    final link = card?.redeemLink;
    if (link == null) return;
    bool extracted = false;
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => CardWebViewScreen(
          url: link,
          title: 'Récupération carte…',
          onCardData: (number, cvv, expiry) async {
            extracted = true;
            final updated = card!.copyWith(cardNumber: number, cvv: cvv, expiry: expiry);
            await updated.save();
            if (mounted) Navigator.of(context).pop();
          },
        ),
      ),
    ).then((_) async {
      if (!extracted || !mounted) return;
      final latest = await VccCard.load();
      if (!mounted) return;
      if (latest != null) setState(() => _card = latest);
      if (latest?.cardNumber != null) {
        showModalBottomSheet(
          context: context,
          backgroundColor: Colors.transparent,
          builder: (_) => _CardDetailsSheet(card: latest!),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(children: [
        // Ambient background blobs — visible in light mode, subtle in dark
        Positioned(
          top: -60, right: -80,
          child: Container(
            width: 280, height: 280,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [
                const Color(0xFF00D4FF).withValues(alpha: AppColors.isDark ? 0.05 : 0.12),
                Colors.transparent,
              ]),
            ),
          ),
        ),
        Positioned(
          top: 160, left: -100,
          child: Container(
            width: 260, height: 260,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [
                const Color(0xFF8B5CF6).withValues(alpha: AppColors.isDark ? 0.04 : 0.08),
                Colors.transparent,
              ]),
            ),
          ),
        ),
        CustomScrollView(slivers: [
        SliverAppBar(
          floating: true,
          backgroundColor: Colors.transparent,
          elevation: 0,
          titleSpacing: 16,
          title: Row(children: [
            Container(
              width: 36, height: 36,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Color(0x7300D4FF),
                    blurRadius: 12,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: ClipOval(
                child: Image.asset('assets/nearpay_logo.png', fit: BoxFit.cover),
              ),
            ),
            const SizedBox(width: 12),
            ShaderMask(
              shaderCallback: (b) => const LinearGradient(
                colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
              ).createShader(b),
              child: const Text('tchipa',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: 4,
                  )),
            ),
          ]),
          actions: [
            if (_card?.isActivated == true)
              IconButton(
                tooltip: 'Actualiser le solde',
                onPressed: _refreshing ? null : _refreshBalance,
                icon: _refreshing
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFF00D4FF)))
                    : const Icon(Icons.refresh_rounded,
                        color: Color(0xFF00D4FF)),
              ),
            const SizedBox(width: 8),
          ],
        ),
        SliverToBoxAdapter(
          child: _loading
              ? const _LoadingCard()
              : Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildSubtitle(),
                      const SizedBox(height: 16),
                      _buildCardWidget(),
                      const SizedBox(height: 24),
                      _buildActions(),
                      if (_card?.isActivated == true) ...[
                        const SizedBox(height: 32),
                        _buildRecentActivity(),
                      ],
                    ],
                  ),
                ),
        ),
      ]),
      ]), // close Stack
    );
  }

  Widget _buildSubtitle() {
    final active = _card?.isActivated == true;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('MA CARTE VIRTUELLE',
          style: TextStyle(
              color: AppColors.textDim,
              fontSize: 11,
              letterSpacing: 2,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      Text(
        active
            ? 'Carte active · Paiements internationaux'
            : 'Activez votre carte pour commencer',
        style: TextStyle(color: AppColors.textSub, fontSize: 13),
      ),
    ]);
  }

  Widget _buildCardWidget() {
    return GestureDetector(
      onTap: () {
        if (_card?.isActivated == true) {
          setState(() => _showFull = !_showFull);
          HapticFeedback.lightImpact();
        }
      },
      child: AnimatedBuilder(
        animation: _shimmerCtrl,
        builder: (_, __) => _VccCardVisual(
          card: _card,
          showFull: _showFull,
          shimmerPhase: _shimmerCtrl.value,
        ),
      ),
    );
  }

  Widget _buildActions() {
    final active = _card?.isActivated == true;

    if (!active) {
      return Column(children: [
        AnimatedBuilder(
          animation: _glowAnim,
          builder: (_, child) {
            final g = _glowAnim.value;
            return Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF00D4FF)
                        .withValues(alpha: 0.25 + g * 0.35),
                    blurRadius: 18 + g * 20,
                    spreadRadius: g * 4,
                  ),
                  BoxShadow(
                    color: const Color(0xFF8B5CF6)
                        .withValues(alpha: 0.2 + g * 0.25),
                    blurRadius: 28 + g * 16,
                  ),
                ],
              ),
              child: child,
            );
          },
          child: _ActionButton(
            label: 'Activer ma carte',
            sublabel: 'Paiement direct USDT · Réseau Polygon',
            icon: Icons.credit_card_rounded,
            colors: const [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
            onTap: _openActivation,
          ),
        ),
        const SizedBox(height: 16),
        _TelegramButton(),
      ]).animate().fadeIn(duration: 400.ms).slideY(begin: 0.08, end: 0);
    }

    return Column(children: [
      _ActionButton(
        label: 'Recharger',
        sublabel: 'Créer une nouvelle carte',
        icon: Icons.add_card_rounded,
        colors: const [Color(0xFF00D4FF), Color(0xFF0096FF)],
        onTap: _openRecharge,
      ),
      const SizedBox(height: 12),
      if (_card?.cardNumber == null && _card?.redeemLink != null)
        _ActionButton(
          label: 'Récupérer ma carte',
          sublabel: 'Extraction automatique des détails',
          icon: Icons.credit_card_rounded,
          colors: const [Color(0xFF8B5CF6), Color(0xFFEC4899)],
          onTap: _openCardLink,
        )
      else
        _ActionButton(
          label: 'Voir les détails',
          sublabel: 'Numéro · CVV · Expiration',
          icon: Icons.visibility_rounded,
          colors: const [Color(0xFF8B5CF6), Color(0xFFEC4899)],
          onTap: _openDetails,
        ),
      const SizedBox(height: 12),
      _TelegramButton(),
    ]).animate().fadeIn(duration: 400.ms);
  }

  Widget _buildRecentActivity() {
    return FutureBuilder<List<VccTx>>(
      future: VccTx.loadAll(),
      builder: (ctx, snap) {
        final txs = (snap.data ?? []).take(3).toList();
        if (txs.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ACTIVITÉ RÉCENTE',
                style: TextStyle(
                    color: AppColors.textDim,
                    fontSize: 11,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            ...txs.map((tx) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _TxRow(tx: tx),
                )),
          ],
        );
      },
    );
  }
}

// ============================================
// VCC CARD VISUAL
// ============================================
class _VccCardVisual extends StatelessWidget {
  final VccCard? card;
  final bool showFull;
  final double shimmerPhase;

  const _VccCardVisual({
    required this.card,
    required this.showFull,
    required this.shimmerPhase,
  });

  @override
  Widget build(BuildContext context) {
    final active = card?.isActivated == true;
    String _rawName = card?.holderName?.isNotEmpty == true
        ? card!.holderName!
        : UserProfile.name.isNotEmpty
            ? UserProfile.name
            : 'NOM COMPLET';
    // strip email address if accidentally included
    if (_rawName.contains('@')) _rawName = _rawName.split(RegExp(r'[\s<@]')).first;
    final holderName = _rawName.toUpperCase();

    return Container(
      height: 216,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: active
              ? const [
                  Color(0xFF1B0B3A),
                  Color(0xFF0A1F6E),
                  Color(0xFF003D5C),
                ]
              : const [
                  Color(0xFF1A1A2E),
                  Color(0xFF16213E),
                  Color(0xFF0F3460),
                ],
        ),
        boxShadow: [
          BoxShadow(
            color: active
                ? const Color(0xFF00D4FF).withValues(alpha: 0.30)
                : const Color(0xFF0F3460).withValues(alpha: 0.45),
            blurRadius: 32, offset: const Offset(0, 12),
          ),
          BoxShadow(
            color: const Color(0xFF8B5CF6).withValues(alpha: 0.18),
            blurRadius: 48, offset: const Offset(0, 18),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Stack(children: [
          // Subtle grid lines
          Positioned.fill(
              child: CustomPaint(
                  painter: _CardGridPainter(active))),
          // Moving shine (active only)
          if (active)
            Positioned.fill(
                child: CustomPaint(
                    painter: _ShimmerPainter(shimmerPhase))),
          // Card content
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment:
                      MainAxisAlignment.spaceBetween,
                  children: [
                    _buildChip(active),
                    _buildBalance(active),
                  ],
                ),
                const Spacer(),
                _buildNumberRow(active, context),
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                        child: _buildNameExpiry(
                            active, holderName)),
                    _buildLogo(active),
                  ],
                ),
              ],
            ),
          ),
          // Tap hint
          if (active)
            Positioned(
              bottom: 6, left: 0, right: 0,
              child: Center(
                child: Text(
                  showFull
                      ? 'Appuyer pour masquer'
                      : 'Appuyer pour révéler le numéro',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.25),
                    fontSize: 10,
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _buildChip(bool active) {
    return Container(
      width: 46, height: 34,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(7),
        gradient: active
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFFFD700), Color(0xFFB8860B)])
            : LinearGradient(colors: [
                Colors.grey.shade700,
                Colors.grey.shade900,
              ]),
      ),
      child: active
          ? null
          : const Center(
              child: Icon(Icons.lock_outline_rounded,
                  color: Colors.white30, size: 16)),
    );
  }

  Widget _buildBalance(bool active) {
    return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Text(
        active ? 'SOLDE DISPONIBLE' : 'NON ACTIVÉE',
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.45),
          fontSize: 9, letterSpacing: 1.5,
        ),
      ),
      const SizedBox(height: 2),
      Text(
        active ? '\$${card!.balance.toStringAsFixed(2)}' : '——',
        style: TextStyle(
          color: active ? Colors.white : Colors.white38,
          fontSize: active ? 24 : 18,
          fontWeight: FontWeight.bold,
        ),
      ),
      if (active)
        Text('USD',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4),
                fontSize: 10,
                letterSpacing: 1)),
    ]);
  }

  Widget _buildNumberRow(bool active, BuildContext context) {
    if (!active) {
      // blurred placeholder — BackdropFilter blurs everything behind it
      return ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
          child: Container(
            padding: const EdgeInsets.symmetric(
                vertical: 4, horizontal: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '•••• •••• •••• ••••',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.3),
                fontSize: 20,
                letterSpacing: 3.5,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      );
    }
    final hasNumber = card!.cardNumber != null && card!.cardNumber!.isNotEmpty;
    if (!hasNumber) {
      final link = card!.redeemLink;
      return GestureDetector(
        onTap: link != null
            ? () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => CardWebViewScreen(url: link)))
            : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Voir ma carte',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75),
                fontSize: 13,
                letterSpacing: 0.5,
                fontStyle: FontStyle.italic,
                decoration: link != null ? TextDecoration.underline : null,
                decorationColor: Colors.white54,
              ),
            ),
            if (link != null) ...[
              const SizedBox(width: 4),
              Icon(Icons.open_in_new_rounded,
                  size: 13, color: Colors.white.withValues(alpha: 0.55)),
            ],
          ],
        ),
      );
    }
    return Text(
      showFull ? card!.formattedNumber : card!.maskedNumber,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 20,
        letterSpacing: 3.5,
        fontFamily: 'monospace',
        fontWeight: FontWeight.w500,
      ),
    );
  }

  Widget _buildNameExpiry(bool active, String holderName) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('TITULAIRE',
          style: TextStyle(
              color: Colors.white.withValues(alpha: 0.35),
              fontSize: 8,
              letterSpacing: 1.5)),
      const SizedBox(height: 2),
      Text(
        holderName,
        style: TextStyle(
          color: active
              ? Colors.white
              : Colors.white.withValues(alpha: 0.5),
          fontSize: 12,
          letterSpacing: 0.8,
        ),
      ),
      const SizedBox(height: 6),
      Row(children: [
        Text('EXP  ',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.35),
                fontSize: 8,
                letterSpacing: 1.5)),
        if (!active)
          ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
              child: Text('••/••',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.3),
                    fontSize: 12,
                    letterSpacing: 1.5,
                  )),
            ),
          )
        else
          Text(card!.expiry ?? '——',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  letterSpacing: 1.5)),
      ]),
    ]);
  }

  Widget _buildLogo(bool active) {
    return SizedBox(
      width: 46, height: 28,
      child: Stack(children: [
        Positioned(
          left: 0,
          child: Container(
            width: 28, height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active
                  ? const Color(0xFFEB001B).withValues(alpha: 0.85)
                  : Colors.grey.shade800.withValues(alpha: 0.4),
            ),
          ),
        ),
        Positioned(
          right: 0,
          child: Container(
            width: 28, height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active
                  ? const Color(0xFFF79E1B).withValues(alpha: 0.85)
                  : Colors.grey.shade700.withValues(alpha: 0.4),
            ),
          ),
        ),
      ]),
    );
  }
}

class _ShimmerPainter extends CustomPainter {
  final double phase;
  _ShimmerPainter(this.phase);

  @override
  void paint(Canvas canvas, Size size) {
    final x = phase * (size.width + 240) - 120;
    final paint = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: 0.05),
          Colors.white.withValues(alpha: 0.13),
          Colors.white.withValues(alpha: 0.05),
          Colors.white.withValues(alpha: 0.0),
        ],
        stops: const [0, 0.3, 0.5, 0.7, 1],
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      ).createShader(Rect.fromLTWH(x - 120, 0, 240, size.height));
    canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height), paint);
  }

  @override
  bool shouldRepaint(_ShimmerPainter old) => phase != old.phase;
}

class _CardGridPainter extends CustomPainter {
  final bool active;
  _CardGridPainter(this.active);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: active ? 0.04 : 0.02)
      ..strokeWidth = 0.5;
    for (var i = 1; i < 8; i++) {
      canvas.drawLine(Offset(size.width * i / 8, 0),
          Offset(size.width * i / 8, size.height), paint);
    }
    for (var i = 1; i < 5; i++) {
      canvas.drawLine(Offset(0, size.height * i / 5),
          Offset(size.width, size.height * i / 5), paint);
    }
  }

  @override
  bool shouldRepaint(_CardGridPainter old) => false;
}

// ============================================
// ACTION BUTTON
// ============================================
class _ActionButton extends StatefulWidget {
  final String label;
  final String sublabel;
  final IconData icon;
  final List<Color> colors;
  final VoidCallback onTap;

  const _ActionButton({
    required this.label,
    required this.sublabel,
    required this.icon,
    required this.colors,
    required this.onTap,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton>
    with SingleTickerProviderStateMixin {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _scale = 0.97),
      onTapUp: (_) { setState(() => _scale = 1.0); widget.onTap(); },
      onTapCancel: () => setState(() => _scale = 1.0),
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 120),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 17, horizontal: 22),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: widget.colors,
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: widget.colors.first.withValues(alpha: 0.35),
                blurRadius: 18, offset: const Offset(0, 6),
              ),
              BoxShadow(
                color: widget.colors.last.withValues(alpha: 0.20),
                blurRadius: 28, offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 38, height: 38,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(widget.icon, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.label,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(widget.sublabel,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.70),
                          fontSize: 11)),
                ],
              ),
              const Spacer(),
              Icon(Icons.arrow_forward_ios_rounded,
                  color: Colors.white.withValues(alpha: 0.5), size: 14),
            ],
          ),
        ),
      ),
    );
  }
}

class _TelegramButton extends StatelessWidget {
  const _TelegramButton();

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        try {
          await launchUrl(Uri.parse(kAgentTelegram),
              mode: LaunchMode.externalApplication);
        } catch (_) {}
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF0088CC), Color(0xFF229ED9)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF0088CC).withValues(alpha: 0.5),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 40, height: 40,
              decoration: const BoxDecoration(
                color: Colors.white24,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.telegram_rounded,
                  color: Colors.white, size: 24),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Commander via Telegram',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold)),
                  SizedBox(height: 3),
                  Text('Un agent traite ta commande rapidement',
                      style: TextStyle(
                          color: Colors.white70,
                          fontSize: 11.5)),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios_rounded,
                color: Colors.white54, size: 16),
          ],
        ),
      ),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      child: Container(
        height: 216,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(22),
        ),
        child: const Center(
            child: CircularProgressIndicator(
                color: Color(0xFF00D4FF), strokeWidth: 2)),
      ),
    );
  }
}

// ============================================
// TRANSACTION ROW
// ============================================
class _TxRow extends StatelessWidget {
  final VccTx tx;
  const _TxRow({required this.tx});

  @override
  Widget build(BuildContext context) {
    final color =
        tx.isDebit ? Colors.redAccent : const Color(0xFF00D4FF);
    final sign = tx.isDebit ? '-' : '+';
    final IconData ico;
    switch (tx.type) {
      case 'activation':
        ico = Icons.credit_card_rounded;
        break;
      case 'recharge':
        ico = Icons.add_card_rounded;
        break;
      default:
        ico = Icons.shopping_bag_rounded;
    }
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
        boxShadow: AppColors.isDark ? null : [
          BoxShadow(
            color: const Color(0xFF6B8EF2).withValues(alpha: 0.07),
            blurRadius: 12, offset: const Offset(0, 3)),
        ],
      ),
      child: Row(children: [
        Container(
          width: 42, height: 42,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(ico, color: color, size: 20),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tx.label,
                  style: TextStyle(
                      color: AppColors.label, fontSize: 14,
                      fontWeight: FontWeight.w500)),
              const SizedBox(height: 3),
              Text(
                '${tx.date.day.toString().padLeft(2, '0')}/'
                '${tx.date.month.toString().padLeft(2, '0')}/'
                '${tx.date.year}  '
                '${tx.date.hour.toString().padLeft(2, '0')}:'
                '${tx.date.minute.toString().padLeft(2, '0')}',
                style: TextStyle(
                    color: AppColors.textDim,
                    fontSize: 11),
              ),
            ],
          ),
        ),
        Text('$sign\$${tx.amount.toStringAsFixed(2)}',
            style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
                fontSize: 15)),
      ]),
    );
  }
}

// ============================================
// ACTIVATION SHEET
// ============================================
enum _ActStep { pick, paying, checking, done }

class _ActivationSheet extends StatefulWidget {
  final void Function(VccCard) onActivated;
  const _ActivationSheet({required this.onActivated});
  @override
  State<_ActivationSheet> createState() => _ActivationSheetState();
}

class _ActivationSheetState extends State<_ActivationSheet> {
  _ActStep _step = _ActStep.pick;
  double _amount = 10.0;
  static const _presets = [10.0, 20.0, 50.0, 100.0];
  static const _kMargin = 0.10;
  bool _customMode = false;
  final _customCtrl = TextEditingController();
  static double _estimatedUsdt(double cardValue) =>
      double.parse((cardValue * 1.0664 * (1 + _kMargin)).toStringAsFixed(2));
  VccOrder? _order;
  String? _redeemLink;
  VccCard? _activatedCard;
  String? _error;

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  Future<void> _createOrder() async {
    setState(() { _step = _ActStep.paying; _error = null; _order = null; });
    try {
      final order = await PayGateService.createVccOrder(
        amount: _amount,
        holderName: UserProfile.name,
        phone: UserProfile.phone,
      );
      setState(() => _order = order);
    } catch (e) {
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
        _step = _ActStep.pick;
      });
    }
  }

  Future<void> _checkStatus() async {
    final id = _order?.redeemId;
    if (id == null) return;
    setState(() { _step = _ActStep.checking; _error = null; });
    try {
      final status = await PayGateService.checkVccStatus(id);
      if (status['isReady'] == true) {
        final link = status['redeemLink'] as String?;
        final card = VccCard(
          cardId: id,
          redeemId: id,
          redeemLink: link,
          balance: _order!.cardValue,
          isActivated: true,
          holderName: UserProfile.name,
        );
        await card.save();
        _activatedCard = card;
        if (mounted) setState(() { _redeemLink = link; _step = _ActStep.done; });
        widget.onActivated(card);
      } else if (status['isPaid'] == true) {
        setState(() {
          _error = 'Paiement reçu — carte en cours d\'émission, revérifiez dans 1 min.';
          _step = _ActStep.paying;
        });
      } else {
        setState(() {
          _error = 'Paiement non reçu. Vérifiez que vous avez envoyé exactement ${_order!.amountUsdt} USDT sur Polygon.';
          _step = _ActStep.paying;
        });
      }
    } catch (e) {
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
        _step = _ActStep.paying;
      });
    }
  }

  void _openLink() {
    final link = _redeemLink;
    final card = _activatedCard;
    if (link == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CardWebViewScreen(
        url: link,
        title: 'Récupération carte…',
        onCardData: card == null ? null : (number, cvv, expiry) async {
          final updated = card.copyWith(cardNumber: number, cvv: cvv, expiry: expiry);
          await updated.save();
          widget.onActivated(updated);
          if (mounted) {
            Navigator.of(context).pop(); // ferme WebView
            Navigator.of(context).pop(); // ferme bottom sheet
          }
        },
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(
          24, 16, 24, MediaQuery.of(context).viewInsets.bottom + 32),
      child: switch (_step) {
        _ActStep.pick     => _buildPicker(),
        _ActStep.paying   => _buildPayment(),
        _ActStep.checking => _buildChecking(),
        _ActStep.done     => _buildDone(),
      },
    );
  }

  Widget _buildPicker() {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _handle(),
          const SizedBox(height: 20),
          Text(L.chooseAmount,
              style: TextStyle(color: AppColors.text, fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(L.payDirectly,
              style: TextStyle(color: AppColors.textSub, fontSize: 13)),
          const SizedBox(height: 20),
          // Presets + bouton Autre
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              ..._presets.map((amt) {
                final sel = !_customMode && _amount == amt;
                return GestureDetector(
                  onTap: () => setState(() { _customMode = false; _amount = amt; }),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                    decoration: BoxDecoration(
                      gradient: sel ? const LinearGradient(
                          colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)]) : null,
                      color: sel ? null : AppColors.card,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: sel ? Colors.transparent
                              : Colors.white.withValues(alpha: 0.08)),
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text('\$${amt.toStringAsFixed(0)}',
                          style: TextStyle(
                              color: sel ? Colors.black : Colors.white,
                              fontWeight: FontWeight.bold, fontSize: 15)),
                      Text('${(_estimatedUsdt(amt) * kExchangeRate).toStringAsFixed(0)} DA',
                          style: TextStyle(
                              color: sel ? Colors.black54 : Colors.white38,
                              fontSize: 10)),
                    ]),
                  ),
                );
              }),
              // Bouton Autre
              GestureDetector(
                onTap: () => setState(() { _customMode = true; }),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  decoration: BoxDecoration(
                    color: _customMode ? const Color(0xFF8B5CF6) : AppColors.card,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: _customMode ? Colors.transparent
                            : Colors.white.withValues(alpha: 0.08)),
                  ),
                  child: Text('Autre',
                      style: TextStyle(
                          color: _customMode ? Colors.white : AppColors.textSub,
                          fontWeight: FontWeight.bold, fontSize: 15)),
                ),
              ),
            ],
          ),
          // Champ montant libre
          if (_customMode) ...[
            const SizedBox(height: 14),
            TextField(
              controller: _customCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: TextStyle(color: AppColors.text, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                prefixText: '\$ ',
                prefixStyle: const TextStyle(color: Color(0xFF00D4FF), fontWeight: FontWeight.bold),
                hintText: 'Montant en USD (min \$5)',
                hintStyle: TextStyle(color: AppColors.textDim),
                filled: true,
                fillColor: AppColors.card,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFF8B5CF6))),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFF8B5CF6), width: 2)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFF8B5CF6))),
              ),
              onChanged: (v) {
                final parsed = double.tryParse(v);
                if (parsed != null && parsed >= 5) setState(() => _amount = parsed);
              },
            ),
          ],
          const SizedBox(height: 16),
          // Récap estimé
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF00D4FF).withValues(alpha: 0.2)),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('Carte Mastercard',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.7))),
              Text('≈ ${_estimatedUsdt(_amount)} USDT',
                  style: const TextStyle(color: Color(0xFF00D4FF), fontWeight: FontWeight.bold)),
            ]),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
          ],
          const SizedBox(height: 20),
          _gradientBtn(
            label: L.createOrder,
            loading: false,
            colors: const [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
            onTap: () {
              if (_customMode) {
                final v = double.tryParse(_customCtrl.text);
                if (v == null || v < 5) {
                  setState(() => _error = 'Montant minimum : \$5');
                  return;
                }
                _amount = v;
              }
              _createOrder();
            },
          ),
          const SizedBox(height: 16),
          // Option agent Telegram
          GestureDetector(
            onTap: () async {
              try {
                await launchUrl(Uri.parse(kAgentTelegram),
                    mode: LaunchMode.externalApplication);
              } catch (_) {}
            },
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF0088CC), Color(0xFF229ED9)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF0088CC).withValues(alpha: 0.45),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(children: [
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.telegram_rounded, color: Colors.white, size: 22),
                  const SizedBox(width: 8),
                  const Text('Passer commande via un Agent',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold)),
                ]),
                const SizedBox(height: 6),
                Text('Rejoins le groupe Telegram · envoi ton nom + montant',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 11.5)),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  static String _paymentUri(String toAddress, String amountUsdt) {
    const usdtPolygon = '0xc2132D05D31c914a87C6611C10748AEb04B58e8F';
    final micro = (double.tryParse(amountUsdt) ?? 0) * 1e6;
    return 'ethereum:$usdtPolygon@137/transfer?address=$toAddress&uint256=${micro.toStringAsFixed(0)}';
  }

  Widget _buildPayment() {
    final order = _order;
    if (order == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 60),
        child: Center(child: CircularProgressIndicator(color: Color(0xFF00D4FF))),
      );
    }
    final addr = order.cryptoAddress;
    final qrData = _paymentUri(addr, order.amountUsdt);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _handle(),
          const SizedBox(height: 20),
          Text(L.sendExactly,
              style: TextStyle(color: AppColors.text, fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(L.usdtPolygonOnly,
              style: TextStyle(color: AppColors.textSub, fontSize: 13)),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF00D4FF).withValues(alpha: 0.4)),
            ),
            child: Column(children: [
              Text(L.exactAmount,
                  style: TextStyle(color: AppColors.textDim, fontSize: 10, letterSpacing: 1.5)),
              const SizedBox(height: 8),
              Text('${order.amountUsdt} USDT',
                  style: const TextStyle(color: Color(0xFF00D4FF),
                      fontSize: 32, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('carte \$${order.cardValue.toStringAsFixed(0)} · réseau Polygon',
                  style: TextStyle(color: AppColors.textDim, fontSize: 12)),
            ]),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(children: [
              Center(
                child: Container(
                  padding: const EdgeInsets.all(10),
                  color: Colors.white,
                  child: QrImageView(data: qrData, size: 150, version: QrVersions.auto),
                ),
              ),
              const SizedBox(height: 12),
              Text('ADRESSE USDT (POLYGON)',
                  style: TextStyle(color: AppColors.textDim, fontSize: 10, letterSpacing: 1.5)),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                  child: Text(addr,
                      style: TextStyle(color: AppColors.textSub, fontSize: 11,
                          fontFamily: 'monospace'),
                      maxLines: 2),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: addr));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Adresse copiée'),
                      duration: Duration(seconds: 2),
                    ));
                  },
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00D4FF).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.copy_rounded, color: Color(0xFF00D4FF), size: 18),
                  ),
                ),
              ]),
            ]),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
            ),
            child: Text(
              '⚠ Envoyez uniquement sur le réseau Polygon. Tout envoi sur un autre réseau sera perdu.',
              style: TextStyle(color: Colors.amber.withValues(alpha: 0.9), fontSize: 12),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.orange, fontSize: 13)),
          ],
          const SizedBox(height: 20),
          _gradientBtn(
            label: 'J\'ai payé — Vérifier',
            loading: false,
            colors: const [Color(0xFF00D4FF), Color(0xFF0096FF)],
            onTap: _checkStatus,
          ),
          const SizedBox(height: 10),
          Center(
            child: Text('ID: ${order.redeemId}',
                style: TextStyle(color: AppColors.textDim, fontSize: 10,
                    fontFamily: 'monospace')),
          ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler', style: TextStyle(color: Colors.white38)),
          ),
        ],
      ),
    );
  }

  Widget _buildChecking() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const CircularProgressIndicator(color: Color(0xFF00D4FF)),
        const SizedBox(height: 20),
        const Text('Vérification du paiement…',
            style: TextStyle(color: Colors.white70)),
        const SizedBox(height: 24),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Retour', style: TextStyle(color: Colors.white38)),
        ),
      ]),
    );
  }

  Widget _buildDone() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _handle(),
        const SizedBox(height: 24),
        Center(
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                  colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)]),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(Icons.check_rounded, color: Colors.black, size: 36),
          ).animate().scale(duration: 400.ms, curve: Curves.elasticOut),
        ),
        const SizedBox(height: 20),
        const Text('Carte activée !',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 22,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text('Votre carte VCC Mastercard est prête.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.5))),
        const SizedBox(height: 24),
        if (_redeemLink != null)
          _gradientBtn(
            label: 'Voir ma carte',
            loading: false,
            colors: const [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
            onTap: _openLink,
          ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Fermer', style: TextStyle(color: Colors.white38)),
        ),
      ],
    );
  }
}

class _Feature extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Feature({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Icon(icon, color: const Color(0xFF00D4FF), size: 18),
        const SizedBox(width: 12),
        Text(text,
            style: const TextStyle(
                color: Colors.white70, fontSize: 14)),
      ]),
    );
  }
}

// ============================================
// RECHARGE SHEET
// ============================================
enum _RechStep { pick, paying, checking, done }

class _RechargeSheet extends StatefulWidget {
  final VccCard card;
  final void Function(double) onSuccess;
  const _RechargeSheet({required this.card, required this.onSuccess});
  @override
  State<_RechargeSheet> createState() => _RechargeSheetState();
}

class _RechargeSheetState extends State<_RechargeSheet> {
  _RechStep _step = _RechStep.pick;
  double _amount = 20.0;
  static const _presets = [10.0, 20.0, 50.0, 100.0];
  static const _kMargin = 0.10;
  static double _estimatedUsdt(double v) =>
      double.parse((v * 1.0664 * (1 + _kMargin)).toStringAsFixed(2));
  VccOrder? _order;
  String? _error;
  String? _redeemLink;
  VccCard? _rechargedCard;

  Future<void> _createOrder() async {
    setState(() { _step = _RechStep.paying; _error = null; _order = null; });
    try {
      final order = await PayGateService.createVccOrder(
        amount: _amount,
        holderName: UserProfile.name,
        phone: UserProfile.phone,
      );
      setState(() => _order = order);
    } catch (e) {
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
        _step = _RechStep.pick;
      });
    }
  }

  Future<void> _checkStatus() async {
    final id = _order?.redeemId;
    if (id == null) return;
    setState(() { _step = _RechStep.checking; _error = null; });
    try {
      final status = await PayGateService.checkVccStatus(id);
      if (status['isReady'] == true) {
        final link = status['redeemLink'] as String?;
        final card = VccCard(
          cardId: id,
          redeemId: id,
          redeemLink: link,
          balance: _order!.cardValue,
          isActivated: true,
          holderName: UserProfile.name,
        );
        await card.save();
        _rechargedCard = card;
        if (mounted) setState(() { _redeemLink = link; _step = _RechStep.done; });
        widget.onSuccess(_order!.cardValue);
      } else if (status['isPaid'] == true) {
        setState(() {
          _error = 'Paiement reçu — carte en cours d\'émission, revérifiez dans 1 min.';
          _step = _RechStep.paying;
        });
      } else {
        setState(() {
          _error = 'Paiement non reçu. Vérifiez que vous avez envoyé exactement ${_order!.amountUsdt} USDT sur Polygon.';
          _step = _RechStep.paying;
        });
      }
    } catch (e) {
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
        _step = _RechStep.paying;
      });
    }
  }

  void _openLink() {
    final link = _redeemLink;
    final card = _rechargedCard;
    if (link == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CardWebViewScreen(
        url: link,
        title: 'Récupération carte…',
        onCardData: card == null ? null : (number, cvv, expiry) async {
          final updated = card.copyWith(cardNumber: number, cvv: cvv, expiry: expiry);
          await updated.save();
          if (mounted) {
            Navigator.of(context).pop(); // ferme WebView
            Navigator.of(context).pop(); // ferme bottom sheet
          }
        },
      ),
    ));
  }

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    padding: EdgeInsets.fromLTRB(24, 16, 24, MediaQuery.of(context).viewInsets.bottom + 32),
    child: switch (_step) {
      _RechStep.pick     => _buildSelector(),
      _RechStep.paying   => _buildPayment(),
      _RechStep.checking => _buildChecking(),
      _RechStep.done     => _buildDone(),
    },
  );

  Widget _buildSelector() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _handle(),
        const SizedBox(height: 24),
        const Text('Nouvelle carte VCC',
            style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Text('Payez directement en USDT sur le réseau Polygon',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 13)),
        const SizedBox(height: 22),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 4,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 1.3,
          children: _presets.map((amt) {
            final sel = _amount == amt;
            return GestureDetector(
              onTap: () => setState(() => _amount = amt),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                decoration: BoxDecoration(
                  gradient: sel
                      ? const LinearGradient(colors: [Color(0xFF00D4FF), Color(0xFF0096FF)])
                      : null,
                  color: sel ? null : AppColors.card,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: sel ? Colors.transparent : Colors.white.withValues(alpha: 0.08)),
                  boxShadow: sel
                      ? [BoxShadow(color: const Color(0xFF00D4FF).withValues(alpha: 0.3), blurRadius: 10)]
                      : [],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('\$$amt',
                        style: TextStyle(
                            color: sel ? Colors.black : Colors.white,
                            fontWeight: FontWeight.bold, fontSize: 16)),
                    Text('${_estimatedUsdt(amt)} USDT',
                        style: TextStyle(
                            color: sel ? Colors.black54 : Colors.white38, fontSize: 10)),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF00D4FF).withValues(alpha: 0.2)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Total à payer',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.6))),
              Text('${_estimatedUsdt(_amount)} USDT',
                  style: const TextStyle(
                      color: Color(0xFF00D4FF),
                      fontWeight: FontWeight.bold, fontSize: 16)),
            ],
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
        ],
        const SizedBox(height: 20),
        _gradientBtn(
          label: 'Créer ma commande',
          loading: false,
          colors: const [Color(0xFF00D4FF), Color(0xFF0096FF)],
          onTap: _createOrder,
        ),
      ],
    );
  }

  static String _paymentUri(String toAddress, String amountUsdt) {
    const usdtPolygon = '0xc2132D05D31c914a87C6611C10748AEb04B58e8F';
    final micro = (double.tryParse(amountUsdt) ?? 0) * 1e6;
    return 'ethereum:$usdtPolygon@137/transfer?address=$toAddress&uint256=${micro.toStringAsFixed(0)}';
  }

  Widget _buildPayment() {
    final order = _order;
    if (order == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 60),
        child: Center(child: CircularProgressIndicator(color: Color(0xFF00D4FF))),
      );
    }
    final addr = order.cryptoAddress;
    final qrData = _paymentUri(addr, order.amountUsdt);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _handle(),
          const SizedBox(height: 20),
          Text(L.sendExactly,
              style: TextStyle(color: AppColors.text, fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(L.usdtPolygonOnly,
              style: TextStyle(color: AppColors.textSub, fontSize: 13)),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF00D4FF).withValues(alpha: 0.4)),
            ),
            child: Column(children: [
              Text(L.exactAmount,
                  style: TextStyle(color: AppColors.textDim, fontSize: 10, letterSpacing: 1.5)),
              const SizedBox(height: 8),
              Text('${order.amountUsdt} USDT',
                  style: const TextStyle(color: Color(0xFF00D4FF),
                      fontSize: 32, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('carte \$${order.cardValue.toStringAsFixed(0)} · réseau Polygon',
                  style: TextStyle(color: AppColors.textDim, fontSize: 12)),
            ]),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(children: [
              Center(
                child: Container(
                  padding: const EdgeInsets.all(10),
                  color: Colors.white,
                  child: QrImageView(data: qrData, size: 150, version: QrVersions.auto),
                ),
              ),
              const SizedBox(height: 12),
              Text('ADRESSE USDT (POLYGON)',
                  style: TextStyle(color: AppColors.textDim, fontSize: 10, letterSpacing: 1.5)),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                  child: Text(addr,
                      style: TextStyle(color: AppColors.textSub, fontSize: 11,
                          fontFamily: 'monospace'),
                      maxLines: 2),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: addr));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Adresse copiée'),
                      duration: Duration(seconds: 2),
                    ));
                  },
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00D4FF).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.copy_rounded, color: Color(0xFF00D4FF), size: 18),
                  ),
                ),
              ]),
            ]),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
            ),
            child: Text(
              '⚠ Envoyez uniquement sur le réseau Polygon. Tout envoi sur un autre réseau sera perdu.',
              style: TextStyle(color: Colors.amber.withValues(alpha: 0.9), fontSize: 12),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.orange, fontSize: 13)),
          ],
          const SizedBox(height: 20),
          _gradientBtn(
            label: 'J\'ai payé — Vérifier',
            loading: false,
            colors: const [Color(0xFF00D4FF), Color(0xFF0096FF)],
            onTap: _checkStatus,
          ),
          const SizedBox(height: 10),
          Center(
            child: Text('ID: ${order.redeemId}',
                style: TextStyle(color: AppColors.textDim, fontSize: 10, fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }

  Widget _buildChecking() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 60),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        CircularProgressIndicator(color: Color(0xFF00D4FF)),
        SizedBox(height: 20),
        Text('Vérification du paiement…', style: TextStyle(color: Colors.white70)),
      ]),
    );
  }

  Widget _buildDone() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _handle(),
        const SizedBox(height: 24),
        Center(
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFF00D4FF), Color(0xFF0096FF)]),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(Icons.check_rounded, color: Colors.black, size: 36),
          ).animate().scale(duration: 400.ms, curve: Curves.elasticOut),
        ),
        const SizedBox(height: 20),
        const Text('Carte prête !',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text('Votre nouvelle carte VCC Mastercard est activée.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.5))),
        const SizedBox(height: 24),
        if (_redeemLink != null)
          _gradientBtn(
            label: 'Voir ma carte',
            loading: false,
            colors: const [Color(0xFF00D4FF), Color(0xFF0096FF)],
            onTap: _openLink,
          ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Fermer', style: TextStyle(color: Colors.white38)),
        ),
      ],
    );
  }

}

// ============================================
// CARD DETAILS SHEET
// ============================================
class _CardDetailsSheet extends StatelessWidget {
  final VccCard card;
  const _CardDetailsSheet({required this.card});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 44),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _handle(),
          const SizedBox(height: 24),
          const Text('Détails de la carte',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 24),
          _DetailRow(label: 'NUMÉRO', value: card.formattedNumber),
          const Divider(color: Colors.white10, height: 1),
          _DetailRow(
              label: 'EXPIRATION', value: card.expiry ?? '—'),
          const Divider(color: Colors.white10, height: 1),
          _DetailRow(label: 'CVV', value: card.cvv ?? '•••'),
          const Divider(color: Colors.white10, height: 1),
          _DetailRow(
              label: 'TITULAIRE',
              value: card.holderName ?? UserProfile.name),
          const Divider(color: Colors.white10, height: 1),
          _DetailRow(
              label: 'SOLDE',
              value: '\$${card.balance.toStringAsFixed(2)} USD'),
          const SizedBox(height: 16),
          Text(
            'Ne partagez jamais ces informations',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.25),
                fontSize: 11,
                fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 11,
                  letterSpacing: 1.2)),
          Row(children: [
            Text(value,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontFamily: 'monospace',
                    letterSpacing: 0.8)),
            const SizedBox(width: 10),
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: value));
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('$label copié'),
                  duration: const Duration(seconds: 1),
                  backgroundColor: AppColors.card,
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ));
              },
              child: const Icon(Icons.copy_rounded,
                  color: Colors.white24, size: 15),
            ),
          ]),
        ],
      ),
    );
  }
}

// ============================================
// TRANSACTIONS SCREEN
// ============================================
class TransactionsScreen extends StatelessWidget {
  const TransactionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: Text('Historique',
            style: TextStyle(
                color: AppColors.label, fontWeight: FontWeight.bold)),
      ),
      body: FutureBuilder<List<VccTx>>(
        future: VccTx.loadAll(),
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(
                child: CircularProgressIndicator(
                    color: Color(0xFF00D4FF)));
          }
          final txs = snap.data ?? [];
          if (txs.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.receipt_long_rounded,
                      color: AppColors.border,
                      size: 72),
                  const SizedBox(height: 16),
                  Text('Aucune transaction',
                      style: TextStyle(
                          color: AppColors.textSub,
                          fontSize: 16)),
                  const SizedBox(height: 6),
                  Text('Activez votre carte pour commencer',
                      style: TextStyle(
                          color: AppColors.textDim,
                          fontSize: 13)),
                ],
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(20),
            itemCount: txs.length,
            separatorBuilder: (_, __) =>
                const SizedBox(height: 8),
            itemBuilder: (_, i) => _TxRow(tx: txs[i]),
          );
        },
      ),
    );
  }
}

// ============================================
// PROFILE SCREEN
// ============================================
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameCtrl;
  late TextEditingController _phoneCtrl;
  late TextEditingController _emailCtrl;
  bool _saving = false;
  bool _lockEnabled = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl  = TextEditingController(text: UserProfile.name);
    _phoneCtrl = TextEditingController(text: UserProfile.phone);
    _emailCtrl = TextEditingController(text: UserProfile.email);
    AppLock.isEnabled().then((v) { if (mounted) setState(() => _lockEnabled = v); });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    UserProfile.name  = _nameCtrl.text.trim();
    UserProfile.phone = _phoneCtrl.text.trim();
    UserProfile.email = _emailCtrl.text.trim();
    await UserProfile.save();
    setState(() => _saving = false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Row(children: [
        Icon(Icons.check_circle_rounded, color: Color(0xFF00D4FF)),
        SizedBox(width: 10),
        Text('Profil enregistré',
            style: TextStyle(color: Colors.white)),
      ]),
      backgroundColor: AppColors.surface,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12)),
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final initial = UserProfile.name.isNotEmpty
        ? UserProfile.name[0].toUpperCase()
        : '?';
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: Text('Mon profil',
            style: TextStyle(
                color: AppColors.label, fontWeight: FontWeight.bold)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 80, height: 80,
                  margin: const EdgeInsets.symmetric(vertical: 20),
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(colors: [
                      Color(0xFF00D4FF), Color(0xFF8B5CF6)
                    ]),
                  ),
                  child: Center(
                    child: Text(initial,
                        style: const TextStyle(
                            color: Colors.black,
                            fontSize: 30,
                            fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
              const _FieldLabel('Nom complet *'),
              TextFormField(
                controller: _nameCtrl,
                style: TextStyle(color: AppColors.inputFg),
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  hintText: 'Prénom Nom',
                  hintStyle: TextStyle(color: AppColors.hint),
                ),
                validator: (v) =>
                    v?.trim().isEmpty == true ? 'Requis' : null,
              ),
              const SizedBox(height: 16),
              const _FieldLabel('Téléphone *'),
              TextFormField(
                controller: _phoneCtrl,
                keyboardType: TextInputType.phone,
                style: TextStyle(color: AppColors.inputFg),
                decoration: InputDecoration(
                  hintText: '+213 XXX XXX XXX',
                  hintStyle: TextStyle(color: AppColors.hint),
                ),
                validator: (v) =>
                    v?.trim().isEmpty == true ? 'Requis' : null,
              ),
              const SizedBox(height: 16),
              const _FieldLabel('Email (optionnel)'),
              TextFormField(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                style: TextStyle(color: AppColors.inputFg),
                decoration: InputDecoration(
                  hintText: 'vous@email.com',
                  hintStyle: TextStyle(color: AppColors.hint),
                ),
              ),
              const SizedBox(height: 32),
              _gradientBtn(
                label: 'Enregistrer',
                loading: _saving,
                colors: const [
                  Color(0xFF00D4FF), Color(0xFF8B5CF6)
                ],
                onTap: _save,
              ),
              const SizedBox(height: 28),
              Text(L.settings,
                  style: TextStyle(color: AppColors.textSub, fontSize: 12,
                      fontWeight: FontWeight.w600, letterSpacing: 1.2)),
              const SizedBox(height: 12),
              // — Langue
              _SettingsTile(
                icon: Icons.language_rounded,
                title: L.language,
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  _LangBtn('FR', langNotifier.value == 'fr', () async {
                    await AppSettings.setLang('fr');
                    if (mounted) setState(() {});
                  }),
                  const SizedBox(width: 8),
                  _LangBtn('AR', langNotifier.value == 'ar', () async {
                    await AppSettings.setLang('ar');
                    if (mounted) setState(() {});
                  }),
                ]),
              ),
              const SizedBox(height: 10),
              // — Thème
              _SettingsTile(
                icon: darkModeNotifier.value
                    ? Icons.dark_mode_rounded
                    : Icons.light_mode_rounded,
                title: darkModeNotifier.value ? L.darkMode : L.lightMode,
                trailing: Switch(
                  value: !darkModeNotifier.value,
                  onChanged: (v) async {
                    await AppSettings.setDark(!v);
                    if (mounted) setState(() {});
                  },
                  thumbColor: WidgetStateProperty.all(const Color(0xFF00D4FF)),
                  trackColor: WidgetStateProperty.all(const Color(0xFF00D4FF).withValues(alpha: 0.3)),
                ),
              ),
              const SizedBox(height: 10),
              // — Biométrique
              _SettingsTile(
                icon: Icons.fingerprint_rounded,
                title: L.biometric,
                subtitle: L.biometricSub,
                trailing: Switch(
                  value: _lockEnabled,
                  onChanged: (v) async {
                    if (v) {
                      final ok = await AppLock.authenticate(context);
                      if (!ok) return;
                    }
                    await AppLock.setEnabled(v);
                    if (mounted) setState(() => _lockEnabled = v);
                  },
                  thumbColor: WidgetStateProperty.all(const Color(0xFF00D4FF)),
                  trackColor: WidgetStateProperty.all(const Color(0xFF00D4FF).withValues(alpha: 0.3)),
                ),
              ),
              const SizedBox(height: 20),
              GestureDetector(
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const AgentScreen())),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: const Color(0xFF00D4FF).withValues(alpha: 0.25)),
                    borderRadius: BorderRadius.circular(14),
                    color: const Color(0xFF00D4FF).withValues(alpha: 0.05),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.shield_outlined,
                          color: Color(0xFF00D4FF), size: 18),
                      const SizedBox(width: 10),
                      Text(L.agentMode,
                          style: const TextStyle(
                              color: Color(0xFF00D4FF),
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              GestureDetector(
                onTap: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (_) => AlertDialog(
                      backgroundColor: AppColors.surface,
                      title: Text('Réinitialiser la carte',
                          style: TextStyle(color: AppColors.text)),
                      content: Text(
                          'Cette action supprimera toutes les données de ta carte VCC de l\'appareil.',
                          style: TextStyle(color: AppColors.textDim)),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Annuler',
                              style: TextStyle(color: Colors.white54)),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Supprimer',
                              style: TextStyle(color: Colors.redAccent)),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true) {
                    await VccCard.remove();
                    if (mounted) setState(() {});
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: Colors.redAccent.withValues(alpha: 0.25)),
                    borderRadius: BorderRadius.circular(14),
                    color: Colors.redAccent.withValues(alpha: 0.05),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.delete_outline_rounded,
                          color: Colors.redAccent, size: 18),
                      SizedBox(width: 10),
                      Text('Réinitialiser ma carte',
                          style: TextStyle(
                              color: Colors.redAccent,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget trailing;
  const _SettingsTile({required this.icon, required this.title,
      this.subtitle, required this.trailing});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(children: [
        Icon(icon, color: const Color(0xFF00D4FF), size: 22),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(color: AppColors.text, fontSize: 14,
                fontWeight: FontWeight.w600)),
            if (subtitle != null)
              Text(subtitle!, style: TextStyle(color: AppColors.textDim, fontSize: 11)),
          ]),
        ),
        trailing,
      ]),
    );
  }
}

class _LangBtn extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _LangBtn(this.label, this.selected, this.onTap);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          gradient: selected ? const LinearGradient(
              colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)]) : null,
          color: selected ? null : AppColors.card,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label, style: TextStyle(
            color: selected ? Colors.black : AppColors.textSub,
            fontWeight: FontWeight.bold, fontSize: 13)),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text,
          style: const TextStyle(
              color: Colors.white54,
              fontSize: 12,
              letterSpacing: 0.5)),
    );
  }
}

// ============================================
// AGENT SCREEN
// ============================================
class AgentScreen extends StatefulWidget {
  const AgentScreen({super.key});
  @override
  State<AgentScreen> createState() => _AgentScreenState();
}

class _AgentScreenState extends State<AgentScreen>
    with SingleTickerProviderStateMixin {
  static const _correctPin = '1234';

  // PIN lock
  bool _unlocked = false;
  String _pin = '';
  bool _pinError = false;
  late AnimationController _shakeCtrl;
  late Animation<double> _shakeAnim;

  // Form
  final _phoneCtrl   = TextEditingController();
  final _nameCtrl    = TextEditingController();
  final _customCtrl  = TextEditingController();
  bool _isRecharge   = false;
  double _amount     = 7.0;
  bool _customMode   = false;
  static const _presets = [7.0, 10.0, 20.0, 50.0, 100.0, 200.0, 300.0];

  // State
  bool _loading = false;
  String? _error;
  Map<String, dynamic>? _result; // activation result
  String? _rechargeId;            // recharge order ID

  @override
  void initState() {
    super.initState();
    _shakeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 400));
    _shakeAnim = TweenSequence([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: -12.0), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -12.0, end: 12.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 12.0, end: -8.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -8.0, end: 8.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 8.0, end: 0.0), weight: 1),
    ]).animate(_shakeCtrl);
  }

  @override
  void dispose() {
    _shakeCtrl.dispose();
    _phoneCtrl.dispose();
    _nameCtrl.dispose();
    _customCtrl.dispose();
    super.dispose();
  }

  void _pressDigit(String d) {
    if (_pin.length >= 4) return;
    setState(() {
      _pin += d;
      _pinError = false;
    });
    if (_pin.length == 4) {
      Future.delayed(const Duration(milliseconds: 120), _checkPin);
    }
  }

  void _backspace() => setState(() {
        if (_pin.isNotEmpty) _pin = _pin.substring(0, _pin.length - 1);
        _pinError = false;
      });

  void _checkPin() {
    if (_pin == _correctPin) {
      setState(() { _unlocked = true; _pinError = false; });
    } else {
      setState(() { _pin = ''; _pinError = true; });
      _shakeCtrl.forward(from: 0);
    }
  }

  Future<void> _confirm() async {
    final phone = _phoneCtrl.text.trim();
    final name  = _nameCtrl.text.trim();
    if (phone.isEmpty || name.isEmpty) {
      setState(() => _error = 'Téléphone et nom requis');
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final order = await PayGateService.createVccOrder(
        amount: _amount,
        holderName: name,
        phone: phone,
      );
      if (_isRecharge) {
        setState(() {
          _rechargeId = order.redeemId;
          _loading = false;
        });
      } else {
        final card = VccCard(
          cardId: order.redeemId,
          redeemId: order.redeemId,
          balance: 0,
          isActivated: false,
          holderName: name,
        );
        await card.save();
        setState(() {
          _result = {
            'redeemId':  order.redeemId,
            'address':   order.cryptoAddress,
            'amountUsdt': order.amountUsdt,
            'holder':    name,
            'cardValue': order.cardValue,
            'qrCode':    order.qrCodeBase64,
          };
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
        _loading = false;
      });
    }
  }

  void _reset() => setState(() {
        _result = null;
        _rechargeId = null;
        _error = null;
        _phoneCtrl.clear();
        _nameCtrl.clear();
        _customCtrl.clear();
        _isRecharge = false;
        _customMode = false;
        _amount = 7.0;
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        foregroundColor: AppColors.label,
        elevation: 0,
        title: const Text('Mode Agent',
            style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      body: _unlocked ? _buildPanel() : _buildPinLock(),
    );
  }

  // ── PIN LOCK ──────────────────────────────────────────────────
  Widget _buildPinLock() {
    return SafeArea(
      child: Column(children: [
        const SizedBox(height: 40),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF00D4FF).withValues(alpha: 0.1),
            boxShadow: [
              BoxShadow(
                  color: const Color(0xFF00D4FF).withValues(alpha: 0.3),
                  blurRadius: 24),
            ],
          ),
          child: const Icon(Icons.shield_rounded,
              color: Color(0xFF00D4FF), size: 40),
        ),
        const SizedBox(height: 24),
        Text('Code Agent',
            style: TextStyle(
                color: AppColors.label,
                fontSize: 22,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text('Entrez votre code à 4 chiffres',
            style: TextStyle(color: AppColors.hint, fontSize: 13)),
        const SizedBox(height: 36),
        AnimatedBuilder(
          animation: _shakeAnim,
          builder: (_, child) =>
              Transform.translate(offset: Offset(_shakeAnim.value, 0), child: child),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(4, (i) {
              final filled = i < _pin.length;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin: const EdgeInsets.symmetric(horizontal: 10),
                width: 18, height: 18,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _pinError
                      ? Colors.redAccent
                      : filled
                          ? const Color(0xFF00D4FF)
                          : Colors.white12,
                  boxShadow: filled && !_pinError
                      ? [BoxShadow(
                          color: const Color(0xFF00D4FF).withValues(alpha: 0.5),
                          blurRadius: 8)]
                      : null,
                ),
              );
            }),
          ),
        ),
        if (_pinError) ...[
          const SizedBox(height: 12),
          const Text('Code incorrect',
              style: TextStyle(color: Colors.redAccent, fontSize: 13)),
        ],
        const Spacer(),
        // Numpad
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
          child: Column(
            children: [
              for (final row in [
                ['1', '2', '3'],
                ['4', '5', '6'],
                ['7', '8', '9'],
                ['', '0', '⌫'],
              ])
                Row(
                  children: row.map((d) {
                    if (d.isEmpty) return const Expanded(child: SizedBox());
                    return Expanded(
                      child: GestureDetector(
                        onTap: () =>
                            d == '⌫' ? _backspace() : _pressDigit(d),
                        child: Container(
                          margin: const EdgeInsets.all(6),
                          height: 64,
                          decoration: BoxDecoration(
                            color: d == '⌫'
                                ? Colors.transparent
                                : AppColors.card,
                            borderRadius: BorderRadius.circular(14),
                            border: d == '⌫'
                                ? null
                                : Border.all(
                                    color: Colors.white.withValues(alpha: 0.06)),
                          ),
                          child: Center(
                            child: d == '⌫'
                                ? const Icon(Icons.backspace_outlined,
                                    color: Colors.white54, size: 22)
                                : Text(d,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 22,
                                        fontWeight: FontWeight.w500)),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
            ],
          ),
        ),
      ]),
    );
  }

  // ── AGENT PANEL ───────────────────────────────────────────────
  Widget _buildPanel() {
    if (_result != null) return _buildActivationResult();
    if (_rechargeId != null) return _buildRechargeResult();
    return _buildForm();
  }

  Widget _buildForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          // Type toggle
          Container(
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(children: [
              _typeBtn('Activation', !_isRecharge, () {
                setState(() { _isRecharge = false; _amount = 7.0; });
              }),
              _typeBtn('Rechargement', _isRecharge, () {
                setState(() { _isRecharge = true; _amount = 20.0; });
              }),
            ]),
          ),
          const SizedBox(height: 24),
          const _FieldLabel('Téléphone du client *'),
          TextField(
            controller: _phoneCtrl,
            keyboardType: TextInputType.phone,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: '+213 XXX XXX XXX',
              hintStyle: TextStyle(color: AppColors.hint),
              filled: true,
              fillColor: AppColors.card,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide:
                      const BorderSide(color: Color(0xFF00D4FF))),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 14),
            ),
          ),
          const SizedBox(height: 16),
          const _FieldLabel('Nom complet du client *'),
          TextField(
            controller: _nameCtrl,
            textCapitalization: TextCapitalization.words,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Prénom Nom',
              hintStyle: TextStyle(color: AppColors.hint),
              filled: true,
              fillColor: AppColors.card,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide:
                      const BorderSide(color: Color(0xFF00D4FF))),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 14),
            ),
          ),
          if (_isRecharge) ...[
            const SizedBox(height: 20),
            const _FieldLabel('Montant (USD)'),
            Wrap(
              spacing: 8, runSpacing: 8,
              children: [
                ..._presets.where((p) => p != 7.0).map((p) {
                  final sel = !_customMode && _amount == p;
                  return GestureDetector(
                    onTap: () => setState(() { _amount = p; _customMode = false; _customCtrl.clear(); }),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: sel ? const Color(0xFF00D4FF) : AppColors.card,
                        border: sel ? null : Border.all(color: Colors.white.withValues(alpha: 0.1)),
                      ),
                      child: Text('\$${p.toStringAsFixed(0)}',
                          style: TextStyle(
                              color: sel ? Colors.black : Colors.white70,
                              fontWeight: FontWeight.w600)),
                    ),
                  );
                }),
                GestureDetector(
                  onTap: () => setState(() { _customMode = true; }),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: _customMode ? const Color(0xFF8B5CF6) : AppColors.card,
                      border: _customMode ? null : Border.all(color: Colors.white.withValues(alpha: 0.1)),
                    ),
                    child: Text('Autre',
                        style: TextStyle(
                            color: _customMode ? Colors.white : Colors.white70,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
            if (_customMode) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _customCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: TextStyle(color: AppColors.inputFg),
                onChanged: (v) {
                  final parsed = double.tryParse(v);
                  if (parsed != null && parsed >= 5) setState(() => _amount = parsed);
                },
                decoration: InputDecoration(
                  hintText: 'Montant libre (min 5\$)',
                  hintStyle: TextStyle(color: Colors.white38),
                  prefixText: '\$ ',
                  prefixStyle: const TextStyle(color: Color(0xFF00D4FF), fontWeight: FontWeight.bold),
                  filled: true,
                  fillColor: AppColors.card,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Color(0xFF8B5CF6))),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Color(0xFF8B5CF6), width: 2)),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: const Color(0xFF8B5CF6).withValues(alpha: 0.5))),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                ),
              ),
            ],
          ],
          const SizedBox(height: 24),
          // Summary box — shown only for recharge (no fee display for activation)
          if (_isRecharge)
          Container(
            padding: const EdgeInsets.symmetric(
                vertical: 14, horizontal: 20),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: const Color(0xFF00D4FF).withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Montant à encaisser',
                    style: TextStyle(
                        color: AppColors.textSub,
                        fontSize: 13)),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('\$${_amount.toStringAsFixed(0)} USD',
                      style: const TextStyle(
                          color: Color(0xFF00D4FF),
                          fontSize: 16,
                          fontWeight: FontWeight.bold)),
                  Text(
                      '${(_amount * kExchangeRate).toStringAsFixed(0)} DA',
                      style: TextStyle(
                          color: AppColors.textDim,
                          fontSize: 11)),
                ]),
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                  color: Colors.redAccent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10)),
              child: Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.redAccent, fontSize: 13)),
            ),
          ],
          const SizedBox(height: 24),
          _gradientBtn(
            label: _isRecharge
                ? 'Confirmer le rechargement'
                : 'Activer la carte',
            loading: _loading,
            colors: const [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
            onTap: _confirm,
          ),
        ],
      ),
    );
  }

  Widget _typeBtn(String label, bool active, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          margin: const EdgeInsets.all(4),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            gradient: active
                ? const LinearGradient(
                    colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)])
                : null,
          ),
          child: Text(label,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: active ? Colors.black : AppColors.sublabel,
                  fontWeight: FontWeight.w600,
                  fontSize: 13)),
        ),
      ),
    );
  }

  Widget _buildActivationResult() {
    final r = _result!;
    final qr = r['qrCode'] as String?;
    final usdt = r['amountUsdt']?.toString() ?? '—';
    final addr = r['address']?.toString() ?? '—';
    final cardVal = r['cardValue'];
    final cardValStr = cardVal != null ? '\$${(cardVal as num).toStringAsFixed(0)}' : '';
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF00D4FF).withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.receipt_long_rounded,
                  color: Color(0xFF00D4FF), size: 48),
            ),
          ),
          const SizedBox(height: 16),
          Text('Commande créée — envoyer USDT${ cardValStr.isNotEmpty ? " ($cardValStr)" : "" }',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(r['holder']?.toString() ?? '',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 14)),
          const SizedBox(height: 20),
          if (qr != null && qr.isNotEmpty) ...[
            Center(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Image.memory(
                  base64Decode(qr),
                  width: 160,
                  height: 160,
                  fit: BoxFit.contain,
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          _infoCard('Montant USDT (Polygon)', '$usdt USDT', Icons.toll_rounded),
          const SizedBox(height: 12),
          _infoCard('Envoyer USDT ici (Polygon)', addr, Icons.account_balance_wallet_rounded),
          const SizedBox(height: 12),
          _infoCard('Redeem ID', r['redeemId']?.toString() ?? '—', Icons.tag_rounded),
          const SizedBox(height: 28),
          _gradientBtn(
            label: 'Nouvelle opération',
            loading: false,
            colors: const [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
            onTap: _reset,
          ),
        ],
      ),
    );
  }

  Widget _infoCard(String label, String value, IconData icon) {
    return GestureDetector(
      onTap: () {
        Clipboard.setData(ClipboardData(text: value));
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$label copié'),
          duration: const Duration(seconds: 1),
          backgroundColor: AppColors.card,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
        ));
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: const Color(0xFF00D4FF).withValues(alpha: 0.2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, color: const Color(0xFF00D4FF), size: 14),
              const SizedBox(width: 6),
              Text(label,
                  style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 10,
                      letterSpacing: 1.2)),
              const Spacer(),
              const Icon(Icons.copy_rounded,
                  color: Colors.white24, size: 14),
            ]),
            const SizedBox(height: 8),
            Text(value,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                    letterSpacing: 1.5)),
          ],
        ),
      ),
    );
  }

  Widget _buildRechargeResult() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 40, 20, 40),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFF00D4FF).withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.bolt_rounded,
                color: Color(0xFF00D4FF), size: 48),
          ),
          const SizedBox(height: 20),
          const Text('Rechargement confirmé !',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('Ref: $_rechargeId',
              style: const TextStyle(
                  color: Color(0xFF00D4FF),
                  fontSize: 14,
                  fontFamily: 'monospace')),
          const Spacer(),
          _gradientBtn(
            label: 'Nouvelle opération',
            loading: false,
            colors: const [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
            onTap: _reset,
          ),
        ],
      ),
    );
  }
}

// ============================================
// SHARED HELPERS
// ============================================
Widget _handle() => Center(
      child: Container(
        width: 40, height: 4,
        decoration: BoxDecoration(
          color: Colors.white24,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );

Widget _gradientBtn({
  required String label,
  required bool loading,
  required List<Color> colors,
  required VoidCallback onTap,
}) {
  return GestureDetector(
    onTap: loading ? null : onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: colors),
        borderRadius: BorderRadius.circular(16),
      ),
      child: loading
          ? const Center(
              child: SizedBox(
                width: 22, height: 22,
                child: CircularProgressIndicator(
                    strokeWidth: 2.5, color: Colors.black),
              ),
            )
          : Text(label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.bold,
                  fontSize: 16)),
    ),
  );
}

// ============================================
// ELECTRIC LOGO PAINTER
// ============================================
class _ElectricLogoPainter extends CustomPainter {
  final double phase;
  _ElectricLogoPainter(this.phase);

  // Precomputed arc offsets seeded at 42 — always same shape, animated by phase
  static final List<List<Offset>> _arcs = [];

  static List<List<Offset>> _buildArcs(double r0, double r1) {
    if (_arcs.isNotEmpty) return _arcs;
    final rng = Random(42);
    for (int arc = 0; arc < 12; arc++) {
      final baseAngle = (arc / 12) * 2 * pi;
      final pts = <Offset>[];
      double r = r0;
      double a = baseAngle;
      while (r < r1) {
        pts.add(Offset(cos(a) * r, sin(a) * r));
        r += 5 + rng.nextDouble() * 7;
        a += (rng.nextDouble() - 0.5) * 0.55;
      }
      pts.add(Offset(cos(a) * r1, sin(a) * r1));
      _arcs.add(pts);
    }
    return _arcs;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final center = Offset(cx, cy);
    final short = size.shortestSide;
    final r0 = short * 0.30;
    final r1 = short * 0.50;
    final t = phase / (2 * pi); // 0..1

    final arcs = _buildArcs(r0, r1);

    // ── Pulsing concentric rings ──
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    for (int i = 0; i < 5; i++) {
      final rt = (t + i * 0.2) % 1.0;
      final radius = r0 + rt * (r1 + short * 0.12 - r0);
      final opacity = (1 - rt) * 0.5;
      ringPaint.color = const Color(0xFF00D4FF).withValues(alpha: opacity);
      canvas.drawCircle(center, radius, ringPaint);
    }

    // ── Electric arcs ──
    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round;

    for (int i = 0; i < arcs.length; i++) {
      final arcT = (t * 4 + i / arcs.length) % 1.0;
      final opacity = arcT < 0.5 ? arcT * 2 : (1 - arcT) * 2;
      final isBlue = i % 3 != 0;
      arcPaint.color = (isBlue
              ? const Color(0xFF00D4FF)
              : const Color(0xFF8B5CF6))
          .withValues(alpha: (opacity * 0.85).clamp(0.0, 1.0));

      final pts = arcs[i];
      final path = Path()..moveTo(center.dx + pts[0].dx, center.dy + pts[0].dy);
      for (int j = 1; j < pts.length; j++) {
        path.lineTo(center.dx + pts[j].dx, center.dy + pts[j].dy);
      }
      canvas.drawPath(path, arcPaint);

      // Spark at tip
      final tip = Offset(center.dx + pts.last.dx, center.dy + pts.last.dy);
      canvas.drawCircle(
        tip,
        2.5,
        Paint()
          ..color = const Color(0xFF00D4FF).withValues(alpha: opacity * 0.9)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
    }

    // ── Rotating dashed orbit ring ──
    final orbitPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..color = const Color(0xFF00D4FF).withValues(alpha: 0.18);
    canvas.drawCircle(center, r0 - 4, orbitPaint);

    // ── Orbiting electron dots ──
    for (int d = 0; d < 3; d++) {
      final angle = phase + d * 2 * pi / 3;
      final pos = Offset(center.dx + cos(angle) * (r0 - 4),
          center.dy + sin(angle) * (r0 - 4));
      canvas.drawCircle(
        pos,
        4.5,
        Paint()
          ..color = const Color(0xFF00D4FF).withValues(alpha: 0.3)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
      canvas.drawCircle(pos, 2.0,
          Paint()..color = const Color(0xFF00D4FF).withValues(alpha: 0.95));
      canvas.drawCircle(pos, 0.8,
          Paint()..color = Colors.white.withValues(alpha: 0.9));
    }

    // ── Central glow halo ──
    final glow = (sin(phase * 2.3) + 1) * 0.5;
    canvas.drawCircle(
      center,
      r0 * 0.85,
      Paint()
        ..color = const Color(0xFF00D4FF).withValues(alpha: 0.06 + glow * 0.08)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 24),
    );
  }

  @override
  bool shouldRepaint(_ElectricLogoPainter old) => old.phase != phase;
}

// ============================================
// CARD WEBVIEW SCREEN
// ============================================
class CardWebViewScreen extends StatefulWidget {
  final String url;
  final String title;
  final void Function(String? cardNumber, String? cvv, String? expiry)? onCardData;
  const CardWebViewScreen({super.key, required this.url, this.title = 'Ma carte', this.onCardData});

  @override
  State<CardWebViewScreen> createState() => _CardWebViewScreenState();
}

class _CardWebViewScreenState extends State<CardWebViewScreen> {
  late final WebViewController _controller;
  bool _loading = true;
  bool _extracted = false;
  bool _showFallback = false; // true only if extraction failed after timeout

  // Injected after page load to pull card details from the DOM + regex fallback
  static const _kExtractJs = r'''
(function(){
  setTimeout(function(){
    try {
      var b = document.body ? document.body.innerText : '';
      var r = {};
      function tryEl(sels) {
        for (var i = 0; i < sels.length; i++) {
          try {
            var el = document.querySelector(sels[i]);
            if (el) {
              var t = (el.value||el.textContent||el.innerText||'').trim().replace(/\s+/g,' ');
              if (t.length > 0) return t;
            }
          } catch(e) {}
        }
        return null;
      }
      r.n = tryEl(["[class*='card-number']","[class*='cardNumber']","[class*='card_number']",
                   "[id*='card-number']","[id*='cardNumber']","[data-card-number]",
                   "[class*='pan']","[id*='pan']"]);
      r.c = tryEl(["[class*='cvv']","[class*='cvc']","[id*='cvv']","[id*='cvc']","[data-cvv]"]);
      r.e = tryEl(["[class*='expiry']","[class*='expir']","[class*='exp-date']",
                   "[class*='expDate']","[id*='expiry']","[data-expiry]","[class*='valid']"]);
      if (!r.n || !/\d{4}/.test(r.n)) {
        var m = b.match(/\b(\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4})\b/);
        r.n = m ? m[1].replace(/[\s-]/g,'') : r.n;
      } else { r.n = r.n.replace(/[\s-]/g,''); }
      if (!r.c || !/^\d{3,4}$/.test(r.c.trim())) {
        var m2 = b.match(/CVV[^\d]{0,10}(\d{3,4})/i)||b.match(/CVC[^\d]{0,10}(\d{3,4})/i)
                ||b.match(/Security[^\d]{0,15}(\d{3,4})/i);
        if (m2) r.c = m2[1];
      }
      if (!r.e || !/\d[\/]\d/.test(r.e)) {
        var m3 = b.match(/\b(0[1-9]|1[0-2])[\/\-](\d{2,4})\b/);
        if (m3) r.e = m3[0];
      }
      TchipaCard.postMessage(JSON.stringify({cardNumber:r.n,cvv:r.c,expiry:r.e}));
    } catch(err){TchipaCard.postMessage(JSON.stringify({error:err.toString()}));}
  },1500);
})();
''';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(AppColors.bg)
      ..addJavaScriptChannel('TchipaCard', onMessageReceived: (msg) {
        if (_extracted || widget.onCardData == null) return;
        try {
          final data = jsonDecode(msg.message) as Map<String, dynamic>;
          if (data['error'] != null) return;
          final number = data['cardNumber'] as String?;
          final cvv = data['cvv'] as String?;
          final expiry = data['expiry'] as String?;
          if (number != null && number.length >= 15) {
            _extracted = true;
            widget.onCardData!(number, cvv, expiry);
          }
        } catch (_) {}
      })
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => setState(() => _loading = true),
        onPageFinished: (_) {
          setState(() => _loading = false);
          if (widget.onCardData != null) {
            _controller.runJavaScript(_kExtractJs);
            // If extraction hasn't succeeded after 6s, reveal the page as fallback
            Future.delayed(const Duration(seconds: 6), () {
              if (!_extracted && mounted) setState(() => _showFallback = true);
            });
          }
        },
      ))
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(widget.title,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white54),
            onPressed: () => _controller.reload(),
          ),
        ],
      ),
      body: Stack(children: [
        WebViewWidget(controller: _controller),
        // Hide the PayGate page behind our loading screen until extraction succeeds.
        // Only removed (_showFallback) if JS extraction fails after 6s.
        if (!_showFallback)
          Container(
            color: AppColors.bg,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 56, height: 56,
                    child: CircularProgressIndicator(
                      color: Color(0xFF00D4FF),
                      strokeWidth: 2.5,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text('Récupération de votre carte…',
                      style: TextStyle(color: AppColors.sublabel, fontSize: 15)),
                  const SizedBox(height: 8),
                  Text('Quelques secondes',
                      style: TextStyle(color: AppColors.hint, fontSize: 13)),
                ],
              ),
            ),
          ),
      ]),
    );
  }
}
