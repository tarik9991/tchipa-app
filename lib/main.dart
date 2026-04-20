import 'dart:ui';
import 'dart:math';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:screenshot/screenshot.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

// ============================================
// CONFIGURATION
// ============================================
const String VPS_SERVER_IP = '76.13.255.239';
const double EXCHANGE_RATE = 242.0;

// ============================================
// CART STATE
// ============================================
class CartItem {
  final String name;
  final String image;
  final double priceUSD;
  int quantity;
  final String productId; // AliExpress numeric product ID, or '0' if unknown
  final String variantId; // SKU ID from AliExpress, or '0' if no variant

  CartItem({
    required this.name,
    required this.image,
    required this.priceUSD,
    this.quantity = 1,
    this.productId = '0',
    this.variantId = '0',
  });

  double get lineUSDT => priceUSD * 1.10 * quantity;
  double get lineDZD => lineUSDT * EXCHANGE_RATE;

  Map<String, dynamic> toJson() => {
        'name': name,
        'image': image,
        'priceUSD': priceUSD,
        'quantity': quantity,
        'productId': productId,
        'variantId': variantId,
      };

  factory CartItem.fromJson(Map<String, dynamic> j) => CartItem(
        name: j['name'] as String,
        image: j['image'] as String,
        priceUSD: (j['priceUSD'] as num).toDouble(),
        quantity: (j['quantity'] as num?)?.toInt() ?? 1,
        productId: j['productId']?.toString() ?? '0',
        variantId: j['variantId']?.toString() ?? '0',
      );
}

class Cart {
  static final List<CartItem> items = [];
  static final _listeners = <VoidCallback>[];

  static void addListener(VoidCallback cb) => _listeners.add(cb);
  static void removeListener(VoidCallback cb) => _listeners.remove(cb);
  static void _notify() {
    for (final cb in _listeners) {
      cb();
    }
    save();
  }

  static Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = items.map((i) => jsonEncode(i.toJson())).toList();
    await prefs.setStringList('cart_items', encoded);
  }

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = prefs.getStringList('cart_items') ?? [];
    items.clear();
    for (final s in encoded) {
      try {
        items.add(CartItem.fromJson(jsonDecode(s) as Map<String, dynamic>));
      } catch (_) {}
    }
  }

  static void add(CartItem newItem) {
    // Match on productId+variantId when available; fall back to name+image
    final idx = (newItem.productId != '0')
        ? items.indexWhere((i) =>
            i.productId == newItem.productId &&
            i.variantId == newItem.variantId)
        : items.indexWhere(
            (i) => i.name == newItem.name && i.image == newItem.image);
    if (idx >= 0) {
      items[idx].quantity++;
    } else {
      items.add(newItem);
    }
    _notify();
  }

  static void remove(int index) {
    if (index >= 0 && index < items.length) {
      items.removeAt(index);
      _notify();
    }
  }

  static void decrement(int index) {
    if (index >= 0 && index < items.length) {
      if (items[index].quantity > 1) {
        items[index].quantity--;
      } else {
        items.removeAt(index);
      }
      _notify();
    }
  }

  static double get totalUSDT =>
      items.fold(0.0, (s, i) => s + i.lineUSDT);
  static double get totalDZD => totalUSDT * EXCHANGE_RATE;
}

// ============================================
// USER PROFILE
// ============================================
class UserProfile {
  static String name = '';
  static String phone = '';
  static String email = '';
  static String address = '';
  static bool get isEmpty => name.trim().isEmpty || phone.trim().isEmpty;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    name    = prefs.getString('profile_name')    ?? '';
    phone   = prefs.getString('profile_phone')   ?? '';
    email   = prefs.getString('profile_email')   ?? '';
    address = prefs.getString('profile_address') ?? '';
  }

  static Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('profile_name',    name);
    await prefs.setString('profile_phone',   phone);
    await prefs.setString('profile_email',   email);
    await prefs.setString('profile_address', address);
  }
}

// ============================================
// VARIANT DATA MODELS
// ============================================
class VariantPropValue {
  final String value;
  final String? image;
  const VariantPropValue({required this.value, this.image});
}

class VariantSku {
  final String? skuId;
  final double priceUSD;
  final int stock;
  final Map<String, VariantPropValue> props;
  const VariantSku({
    this.skuId,
    required this.priceUSD,
    required this.stock,
    required this.props,
  });

  factory VariantSku.fromJson(Map<String, dynamic> j) {
    final props = <String, VariantPropValue>{};
    final rawProps = j['props'] as Map<String, dynamic>? ?? {};
    rawProps.forEach((k, v) {
      props[k] = VariantPropValue(
        value: (v as Map<String, dynamic>)['value'] as String? ?? '',
        image: v['image'] as String?,
      );
    });
    return VariantSku(
      skuId: j['skuId']?.toString(),
      priceUSD: (j['priceUSD'] as num?)?.toDouble() ?? 0,
      stock: (j['stock'] as num?)?.toInt() ?? 0,
      props: props,
    );
  }
}

/// A single property dimension (e.g. "Color", "Shoe Size", "EU Size").
class VariantProperty {
  final String name;
  final List<String> values;
  const VariantProperty({required this.name, required this.values});
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Future.wait([Cart.load(), UserProfile.load()]);
  runApp(const TchipaApp());
}

// ============================================
// APP PRINCIPALE
// ============================================
class TchipaApp extends StatelessWidget {
  const TchipaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'tchipa',
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        primaryColor: const Color(0xFF00D4FF),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00D4FF),
          brightness: Brightness.dark,
        ),
        fontFamily: 'SF Pro Display',
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF0F1923),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      home: const SplashScreen(),
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
  // Image fades in over 800 ms
  late AnimationController _imgCtrl;
  late Animation<double> _imgFade;

  // Overlay (name + spinner) slides up after image settles
  late AnimationController _overlayCtrl;
  late Animation<double> _overlayFade;
  late Animation<Offset> _overlaySlide;

  static const String _splashImage =
      'https://i.ibb.co/QF18Dz91/Gemini-Generated-Image-1h03up1h03up1h03.png';

  @override
  void initState() {
    super.initState();

    _imgCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _imgFade = CurvedAnimation(parent: _imgCtrl, curve: Curves.easeIn);

    _overlayCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _overlayFade  = CurvedAnimation(parent: _overlayCtrl, curve: Curves.easeIn);
    _overlaySlide = Tween<Offset>(
      begin: const Offset(0, 0.12),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _overlayCtrl, curve: Curves.easeOut));

    _imgCtrl.forward().then((_) => _overlayCtrl.forward());

    // Navigate after 3.2 s total
    Future.delayed(const Duration(milliseconds: 3200), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => const MainScreen(),
          transitionDuration: const Duration(milliseconds: 600),
          transitionsBuilder: (_, anim, __, child) =>
              FadeTransition(opacity: anim, child: child),
        ),
      );
    });
  }

  @override
  void dispose() {
    _imgCtrl.dispose();
    _overlayCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Full-screen splash image ──
          FadeTransition(
            opacity: _imgFade,
            child: Image.network(
              _splashImage,
              width: size.width,
              height: size.height,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                color: const Color(0xFF0D1117),
                child: const Center(
                  child: Icon(Icons.image_not_supported_outlined,
                      color: Colors.white24, size: 64),
                ),
              ),
            ),
          ),

          // ── Dark gradient scrim at the bottom ──
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
                    Colors.black.withOpacity(0.85),
                  ],
                ),
              ),
            ),
          ),

          // ── App name + spinner overlay ──
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
                      shaderCallback: (bounds) => const LinearGradient(
                        colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
                      ).createShader(bounds),
                      child: const Text(
                        'tchipa',
                        style: TextStyle(
                          fontSize: 42,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: 8,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Smart Checkout · AliExpress & Temu',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.55),
                        fontSize: 13,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 32),
                    SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          const Color(0xFF00D4FF).withOpacity(0.8),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================
// ECRAN PRINCIPAL
// ============================================
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  final List<Widget> _screens = [
    const HomeScreen(),
    const CartScreen(),
    const HistoryScreen(),
    const ProfileScreen(),
  ];

  @override
  void initState() {
    super.initState();
    Cart.addListener(_onCartChanged);
    // If profile is incomplete, redirect to Profile tab after first frame
    if (UserProfile.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() => _currentIndex = 3);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(children: [
              Icon(Icons.person_outline, color: Color(0xFF00D4FF)),
              SizedBox(width: 10),
              Text('Complétez votre profil pour commencer',
                  style: TextStyle(color: Colors.white)),
            ]),
            backgroundColor: const Color(0xFF0F1923),
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            duration: const Duration(seconds: 3),
          ),
        );
      });
    }
  }

  @override
  void dispose() {
    Cart.removeListener(_onCartChanged);
    super.dispose();
  }

  void _onCartChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_currentIndex],
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF0F1923), Color(0xFF0D1117)],
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 20,
              offset: const Offset(0, -5),
            ),
          ],
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (i) => setState(() => _currentIndex = i),
          backgroundColor: Colors.transparent,
          elevation: 0,
          selectedItemColor: const Color(0xFF00D4FF),
          unselectedItemColor: Colors.white38,
          items: [
            const BottomNavigationBarItem(
              icon: Icon(Icons.home_rounded),
              label: 'Accueil',
            ),
            BottomNavigationBarItem(
              icon: Badge(
                label: Cart.items.isEmpty
                    ? null
                    : Text('${Cart.items.length}'),
                isLabelVisible: Cart.items.isNotEmpty,
                child: const Icon(Icons.shopping_cart_rounded),
              ),
              label: 'Panier',
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.history_rounded),
              label: 'Historique',
            ),
            BottomNavigationBarItem(
              icon: Badge(
                isLabelVisible: UserProfile.isEmpty,
                label: const Text('!'),
                child: const Icon(Icons.person_rounded),
              ),
              label: 'Profil',
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================
// ECRAN D'ACCUEIL - SCANNER PRODUIT
// ============================================
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  final TextEditingController _linkController = TextEditingController();
  final TextEditingController _priceController = TextEditingController();
  final ScreenshotController _screenshotController = ScreenshotController();

  bool _isLoading = false;
  double _originalPrice = 0.0;
  double _totalUsdt = 0.0;
  double _totalDzd = 0.0;
  String _orderID = "";
  String _productName = "";
  String _productImage = "";
  // Variant selections captured when user returns from ProductDetailScreen
  Map<String, String> _selectedVariants = {};
  String _selectedProductId = '0';
  String _selectedSkuId = '0';

  late AnimationController _flagController;
  late Animation<double> _flagAnimation;

  @override
  void initState() {
    super.initState();
    _flagController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
    _flagAnimation =
        Tween<double>(begin: 0, end: 2 * pi).animate(_flagController);
  }

  @override
  void dispose() {
    _flagController.dispose();
    _linkController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  // --- RAPIDAPI VPS ---
  Future<void> _fetchPriceFromScraper() async {
    String url = _linkController.text.trim();
    if (url.isEmpty) {
      _showToast("Veuillez entrer un lien produit");
      return;
    }

    setState(() => _isLoading = true);

    try {
      final response = await http
          .get(Uri.parse(
              'http://$VPS_SERVER_IP:3000/browse?url=${Uri.encodeComponent(url)}'))
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final name = data['productName']?.toString() ?? '';
        final price = (data['priceUSD'] as num?)?.toDouble() ?? 0.0;
        final image = data['imageUrl']?.toString() ?? '';

        if (name.isEmpty && price == 0) {
          _showToast("Produit non trouvé. Entrez le prix manuellement.");
          return;
        }

        setState(() {
          _productName = name.isNotEmpty ? name : 'Produit AliExpress';
          _productImage = image;
          _priceController.text = price > 0 ? price.toStringAsFixed(2) : '';
          if (price > 0) _calculate();
        });
        _showToast("Produit détecté !");
      } else {
        _showToast("Produit non trouvé. Entrez le prix manuellement.");
      }
    } catch (e) {
      _showToast("Erreur de connexion. Entrez le prix manuellement.");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _onLinkChanged(String value) {
    final trimmed = value.trim();
    if ((trimmed.contains('aliexpress.com/item/') ||
            trimmed.contains('aliexpress.com/i/')) &&
        !_isLoading) {
      _fetchPriceFromScraper();
    }
  }

  void _calculate() {
    setState(() {
      _originalPrice = double.tryParse(_priceController.text) ?? 0.0;
      _totalUsdt = _originalPrice * 1.10;
      _totalDzd = _totalUsdt * EXCHANGE_RATE;
      _orderID = "NP-${Random().nextInt(9000) + 1000}";
    });
  }

  // --- DIALOG QR CODE ---
  void _showCouponDialog() {
    if (_totalUsdt <= 0) {
      _showToast("Calculez d'abord un prix");
      return;
    }

    showDialog(
      context: context,
      builder: (context) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: AlertDialog(
          backgroundColor: const Color(0xFF0F1923),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Screenshot(
                controller: _screenshotController,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        const Color(0xFF00D4FF).withOpacity(0.1),
                        const Color(0xFF8B5CF6).withOpacity(0.1),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _buildMiniCircuitFlag(),
                          const SizedBox(width: 10),
                          const Text(
                            "TCHIPA",
                            style: TextStyle(
                              color: Color(0xFF00D4FF),
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 15),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(15),
                        ),
                        child: QrImageView(
                          data: () {
                            // Extract product ID from URL if not already captured
                            final prodId = (_selectedProductId != '0' &&
                                    _selectedProductId.isNotEmpty)
                                ? _selectedProductId
                                : (RegExp(r'/item/(\d+)')
                                        .firstMatch(
                                            _linkController.text.trim())
                                        ?.group(1) ??
                                    '0');
                            // Format: NP|TX_ID|TOTAL_USDT|PROD_ID:VAR_ID:QTY
                            return 'NP|$_orderID|${_totalUsdt.toStringAsFixed(2)}|$prodId:$_selectedSkuId:1';
                          }(),
                          version: QrVersions.auto,
                          size: 180,
                          eyeStyle: const QrEyeStyle(
                            eyeShape: QrEyeShape.square,
                            color: Color(0xFF00D4FF),
                          ),
                        ),
                      ),
                      const SizedBox(height: 15),
                      Text(
                        "ID: $_orderID",
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        "${_totalUsdt.toStringAsFixed(2)} USDT",
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF00D4FF),
                        ),
                      ),
                      Text(
                        "~ ${_totalDzd.toStringAsFixed(0)} DZD",
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Fermer",
                  style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton.icon(
              onPressed: _shareCoupon,
              icon: const Icon(Icons.share),
              label: const Text("Partager"),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00D4FF),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _shareCoupon() async {
    final image = await _screenshotController.capture();
    if (image != null) {
      await Share.shareXFiles(
        [
          XFile.fromData(image,
              name: 'tchipa_coupon.png', mimeType: 'image/png')
        ],
        text:
            'Tchipa - Commande $_orderID - ${_totalUsdt.toStringAsFixed(2)} USDT',
      );
    }
  }

  void _showToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: const Color(0xFF0F1923),
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  double _parseImportedPrice(String raw) {
    final match = RegExp(r'[\d]+(?:[.,]\d+)?').firstMatch(raw.replaceAll(',', '.'));
    return match != null ? double.tryParse(match.group(0)!) ?? 0.0 : 0.0;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF0D1117),
              Color(0xFF0F1923),
              Color(0xFF0D1117),
            ],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                const SizedBox(height: 10),
                _buildHeader(),
                const SizedBox(height: 30),
                _buildInputCard(),
                const SizedBox(height: 20),
                if (_productName.isNotEmpty) _buildProductCard(),
                if (_totalUsdt > 0) ...[
                  const SizedBox(height: 20),
                  _buildResultCard(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      children: [
        // Tchipa logo — layered neon cyan glow ring
        Container(
          width: 104,
          height: 104,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            // Outer diffuse purple halo
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF00D4FF).withOpacity(0.70),
                blurRadius: 36,
                spreadRadius: 6,
              ),
              BoxShadow(
                color: const Color(0xFF8B5CF6).withOpacity(0.45),
                blurRadius: 64,
                spreadRadius: 16,
              ),
            ],
          ),
          child: Stack(
            children: [
              // Cyan neon border ring
              Container(
                width: 104,
                height: 104,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  gradient: const LinearGradient(
                    colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
              ),
              // Inner logo — drawn inline, no network dependency
              Positioned(
                top: 3,
                left: 3,
                right: 3,
                bottom: 3,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(25),
                  child: Container(
                    color: const Color(0xFF0D1117),
                    child: Center(
                      child: ShaderMask(
                        shaderCallback: (bounds) => const LinearGradient(
                          colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ).createShader(bounds),
                        child: const Text(
                          'T',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 56,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -2,
                            height: 1,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ).animate().fadeIn(duration: 600.ms).scale(begin: const Offset(0.8, 0.8)),
        const SizedBox(height: 14),
        ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
          ).createShader(bounds),
          child: const Text(
            "TCHIPA",
            style: TextStyle(
              fontSize: 38,
              fontWeight: FontWeight.bold,
              color: Colors.white,
              letterSpacing: 5,
            ),
          ),
        ).animate().fadeIn(duration: 800.ms, delay: 200.ms),
        const SizedBox(height: 4),
        Text(
          "Smart Checkout · AliExpress & Temu",
          style: TextStyle(
            color: Colors.white.withOpacity(0.5),
            fontSize: 13,
            letterSpacing: 0.5,
          ),
        ).animate().fadeIn(duration: 800.ms, delay: 400.ms),
        const SizedBox(height: 18),
        // Animated circuit-board flag — CustomPaint, glowing PCB traces
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF00FF88).withOpacity(0.30),
                blurRadius: 24,
                spreadRadius: 2,
              ),
              BoxShadow(
                color: const Color(0xFF00D4FF).withOpacity(0.15),
                blurRadius: 16,
                spreadRadius: -2,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: AnimatedBuilder(
              animation: _flagController,
              builder: (_, __) => CustomPaint(
                size: const Size(150, 100),
                painter: CircuitBoardFlagPainter(_flagAnimation.value),
              ),
            ),
          ),
        ).animate().fadeIn(duration: 700.ms, delay: 500.ms),
      ],
    );
  }

  Widget _buildMiniCircuitFlag() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: AnimatedBuilder(
        animation: _flagController,
        builder: (_, __) => CustomPaint(
          size: const Size(50, 34),
          painter: CircuitBoardFlagPainter(_flagAnimation.value, isMini: true),
        ),
      ),
    );
  }

  Widget _buildInputCard() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withOpacity(0.1),
            Colors.white.withOpacity(0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(25),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          // Lien produit
          TextField(
            controller: _linkController,
            style: const TextStyle(color: Colors.white),
            onChanged: _onLinkChanged,
            decoration: InputDecoration(
              hintText: "Collez le lien AliExpress ou Temu",
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
              filled: true,
              fillColor: Colors.white.withOpacity(0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(15),
                borderSide: BorderSide.none,
              ),
              prefixIcon: const Icon(Icons.link, color: Color(0xFF00D4FF)),
              suffixIcon: _isLoading
                  ? Container(
                      width: 20,
                      height: 20,
                      margin: const EdgeInsets.all(12),
                      child: const CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF00D4FF),
                      ),
                    )
                  : IconButton(
                      icon: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.search,
                            color: Colors.black, size: 18),
                      ),
                      onPressed: _fetchPriceFromScraper,
                    ),
            ),
          ),
          const SizedBox(height: 15),
          // Prix manuel
          TextField(
            controller: _priceController,
            style: const TextStyle(color: Colors.white, fontSize: 24),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => _calculate(),
            decoration: InputDecoration(
              hintText: "Prix en \$",
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
              filled: true,
              fillColor: Colors.white.withOpacity(0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(15),
                borderSide: BorderSide.none,
              ),
              prefixIcon:
                  const Icon(Icons.attach_money, color: Color(0xFF00D4FF)),
            ),
          ),
          const SizedBox(height: 15),
          GestureDetector(
            onTap: () async {
              final result = await Navigator.push<Map<String, dynamic>>(
                context,
                MaterialPageRoute(builder: (_) => const ImportWebViewScreen()),
              );
              if (result != null && mounted) {
                final name = result['name']?.toString() ?? 'Produit importé';
                final priceRaw = result['price']?.toString() ?? '0';
                final priceUSD = _parseImportedPrice(priceRaw);
                final variants = result['variants'];
                String variantLabel = '';
                if (variants is List && variants.isNotEmpty) {
                  variantLabel = variants
                      .map((v) => '${v['label']}: ${v['value']}')
                      .join(', ');
                }
                final fullName =
                    variantLabel.isNotEmpty ? '$name — $variantLabel' : name;
                Cart.add(CartItem(
                  name: fullName,
                  image: '',
                  priceUSD: priceUSD,
                ));
                _showToast('✓ Produit ajouté au panier');
              }
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFFF6B35), Color(0xFFFF3CAC)],
                ),
                borderRadius: BorderRadius.circular(15),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFFF6B35).withOpacity(0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.camera_alt_rounded, color: Colors.white, size: 18),
                  SizedBox(width: 8),
                  Text(
                    'Importer Temu / Shein',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 600.ms, delay: 600.ms).slideY(begin: 0.2);
  }

  Widget _buildProductCard() {
    return GestureDetector(
      onTap: () async {
        final variants = await Navigator.push<Map<String, String>>(
          context,
          MaterialPageRoute(
            builder: (_) => ProductDetailScreen(
              productName: _productName,
              productImage: _productImage,
              priceUSD: _originalPrice,
              priceUSDT: _totalUsdt,
              priceDZD: _totalDzd,
              productUrl: _linkController.text.trim(),
            ),
          ),
        );
        if (variants != null && mounted) {
          setState(() {
            _selectedProductId = variants.remove('__productId__') ?? '0';
            _selectedSkuId     = variants.remove('__skuId__')     ?? '0';
            _selectedVariants  = variants;
          });
        }
      },
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              const Color(0xFF00D4FF).withOpacity(0.1),
              const Color(0xFF8B5CF6).withOpacity(0.05),
            ],
          ),
          borderRadius: BorderRadius.circular(20),
          border:
              Border.all(color: const Color(0xFF00D4FF).withOpacity(0.3)),
        ),
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.shopping_bag,
                    color: Color(0xFF00D4FF), size: 20),
                const SizedBox(width: 8),
                const Text(
                  "Produit détecté",
                  style: TextStyle(
                    color: Color(0xFF00D4FF),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                const Icon(Icons.chevron_right,
                    color: Colors.white38, size: 20),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              _productName,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            if (_productImage.isNotEmpty) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.network(
                  _productImage,
                  height: 100,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox(),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.visibility_rounded,
                      color: Colors.black, size: 16),
                  SizedBox(width: 6),
                  Text(
                    "Voir le détail",
                    style: TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.1);
  }

  Widget _buildResultCard() {
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xFF00D4FF).withOpacity(0.15),
                const Color(0xFF8B5CF6).withOpacity(0.1),
              ],
            ),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(
                color: const Color(0xFF00D4FF).withOpacity(0.3)),
          ),
          padding: const EdgeInsets.all(25),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "Prix original",
                    style: TextStyle(color: Colors.white.withOpacity(0.6)),
                  ),
                  Text(
                    "\$${_originalPrice.toStringAsFixed(2)}",
                    style:
                        const TextStyle(color: Colors.white, fontSize: 18),
                  ),
                ],
              ),
              const SizedBox(height: 15),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "TOTAL À PAYER",
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.6),
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFF00D4FF),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: const Text(
                                "USDT",
                                style: TextStyle(
                                  color: Colors.black,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              _totalUsdt.toStringAsFixed(2),
                              style: const TextStyle(
                                color: Color(0xFF00D4FF),
                                fontSize: 32,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const Icon(
                      Icons.trending_up,
                      color: Color(0xFF00D4FF),
                      size: 40,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 15),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "Estimation DZD",
                    style: TextStyle(color: Colors.white.withOpacity(0.6)),
                  ),
                  Text(
                    "~ ${_totalDzd.toStringAsFixed(0)} DA",
                    style: const TextStyle(
                      color: Color(0xFF8B5CF6),
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                "Taux: 1 USDT = $EXCHANGE_RATE DZD",
                style: TextStyle(
                    color: Colors.white.withOpacity(0.4), fontSize: 11),
              ),
            ],
          ),
        ).animate().fadeIn(duration: 600.ms).slideY(begin: 0.2),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _showCouponDialog,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.transparent,
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
            ),
            child: Ink(
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Container(
                padding: const EdgeInsets.all(20),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.qr_code_2, color: Colors.black, size: 28),
                    SizedBox(width: 10),
                    Text(
                      "GÉNÉRER LE QR CODE",
                      style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ).animate().fadeIn(duration: 600.ms, delay: 200.ms),
      ],
    );
  }
}

// ============================================
// ECRAN PANIER
// ============================================
class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  final ScreenshotController _screenshotController = ScreenshotController();
  String _orderID = "";

  @override
  void initState() {
    super.initState();
    Cart.addListener(_onCartChanged);
    _orderID = "NP-${Random().nextInt(9000) + 1000}";
  }

  @override
  void dispose() {
    Cart.removeListener(_onCartChanged);
    super.dispose();
  }

  void _onCartChanged() => setState(() {});

  void _showQrDialog() {
    if (Cart.items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text("Le panier est vide"),
          backgroundColor: const Color(0xFF0F1923),
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }

    _orderID = "NP-${Random().nextInt(9000) + 1000}";

    showDialog(
      context: context,
      builder: (context) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: AlertDialog(
          backgroundColor: const Color(0xFF0F1923),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
          content: SingleChildScrollView(
            child: Screenshot(
              controller: _screenshotController,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      const Color(0xFF00D4FF).withOpacity(0.1),
                      const Color(0xFF8B5CF6).withOpacity(0.1),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header
                    const Text(
                      "TCHIPA",
                      style: TextStyle(
                        color: Color(0xFF00D4FF),
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "Commande $_orderID",
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 11),
                    ),
                    const SizedBox(height: 16),
                    // QR Code
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: QrImageView(
                        data: () {
                          // Format: NP|TX_ID|PROD_ID:VAR_ID:QTY;PROD_ID:VAR_ID:QTY
                          // All constituent parts are digits/alphanumeric — URI-safe.
                          final items = Cart.items
                              .map((i) =>
                                  '${i.productId}:${i.variantId}:${i.quantity}')
                              .join(';');
                          return 'NP|$_orderID|${Cart.totalUSDT.toStringAsFixed(2)}|$items';
                        }(),
                        version: QrVersions.auto,
                        size: 200,
                        eyeStyle: const QrEyeStyle(
                          eyeShape: QrEyeShape.square,
                          color: Color(0xFF00D4FF),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Items summary
                    ...Cart.items.map((item) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              Text(
                                "×${item.quantity}",
                                style: const TextStyle(
                                    color: Color(0xFF00D4FF),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  item.name,
                                  style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 11),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Text(
                                "${item.lineUSDT.toStringAsFixed(2)} USDT",
                                style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 11),
                              ),
                            ],
                          ),
                        )),
                    const Divider(color: Colors.white12, height: 20),
                    // Total USDT
                    Text(
                      "${Cart.totalUSDT.toStringAsFixed(2)} USDT",
                      style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF00D4FF),
                      ),
                    ),
                    // Total DZD
                    Text(
                      "≈ ${Cart.totalDZD.toStringAsFixed(0)} DZD",
                      style: const TextStyle(
                          color: Color(0xFF8B5CF6), fontSize: 15),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      "1 USDT = $EXCHANGE_RATE DZD",
                      style: const TextStyle(
                          color: Colors.white24, fontSize: 10),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Fermer",
                  style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                final image = await _screenshotController.capture();
                if (image != null && context.mounted) {
                  Navigator.pop(context);
                  await Share.shareXFiles(
                    [
                      XFile.fromData(image,
                          name: 'tchipa_panier.png',
                          mimeType: 'image/png')
                    ],
                    text:
                        'Tchipa - Commande $_orderID - ${Cart.totalUSDT.toStringAsFixed(2)} USDT',
                  );
                }
              },
              icon: const Icon(Icons.share),
              label: const Text("Partager"),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00D4FF),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0D1117), Color(0xFF0F1923)],
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.shopping_cart_rounded,
                    color: Colors.black),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Mon Panier",
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    "${Cart.items.length} article${Cart.items.length != 1 ? 's' : ''}",
                    style: const TextStyle(
                        color: Color(0xFF00D4FF), fontSize: 11),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            if (Cart.items.isNotEmpty)
              TextButton(
                onPressed: () {
                  setState(() => Cart.items.clear());
                },
                child: const Text("Vider",
                    style: TextStyle(color: Colors.white38, fontSize: 13)),
              ),
          ],
        ),
        body: Cart.items.isEmpty
            ? _buildEmptyCart()
            : Column(
                children: [
                  Expanded(child: _buildItemList()),
                  _buildTotalBar(),
                ],
              ),
      ),
    );
  }

  Widget _buildEmptyCart() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF00D4FF).withOpacity(0.15),
                  const Color(0xFF8B5CF6).withOpacity(0.1),
                ],
              ),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.shopping_cart_outlined,
              size: 56,
              color: Color(0xFF00D4FF),
            ),
          ).animate().scale(duration: 600.ms),
          const SizedBox(height: 20),
          Text(
            "Panier vide",
            style: TextStyle(
              color: Colors.white.withOpacity(0.6),
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ).animate().fadeIn(delay: 200.ms),
          const SizedBox(height: 8),
          Text(
            "Ajoutez des produits depuis l'accueil",
            style: TextStyle(
              color: Colors.white.withOpacity(0.3),
              fontSize: 14,
            ),
          ).animate().fadeIn(delay: 300.ms),
        ],
      ),
    );
  }

  Widget _buildItemList() {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      itemCount: Cart.items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final item = Cart.items[index];
        return Dismissible(
          key: ValueKey(item.name),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            decoration: BoxDecoration(
              color: Colors.red.withOpacity(0.3),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Icon(Icons.delete_rounded,
                color: Colors.redAccent),
          ),
          onDismissed: (_) => Cart.remove(index),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withOpacity(0.08),
                  Colors.white.withOpacity(0.04),
                ],
              ),
              borderRadius: BorderRadius.circular(18),
              border:
                  Border.all(color: Colors.white.withOpacity(0.08)),
            ),
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                // Image
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: item.image.isNotEmpty
                      ? Image.network(
                          item.image,
                          width: 58,
                          height: 58,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              _itemImagePlaceholder(),
                        )
                      : _itemImagePlaceholder(),
                ),
                const SizedBox(width: 12),
                // Name & price
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "\$${item.priceUSD.toStringAsFixed(2)} / unité",
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 11),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        "${item.lineUSDT.toStringAsFixed(2)} USDT",
                        style: const TextStyle(
                          color: Color(0xFF00D4FF),
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        "≈ ${item.lineDZD.toStringAsFixed(0)} DZD",
                        style: const TextStyle(
                            color: Color(0xFF8B5CF6), fontSize: 11),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Quantity controls
                Column(
                  children: [
                    GestureDetector(
                      onTap: () => Cart.add(CartItem(
                        name: item.name,
                        image: item.image,
                        priceUSD: item.priceUSD,
                        productId: item.productId,
                        variantId: item.variantId,
                      )),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [
                              Color(0xFF00D4FF),
                              Color(0xFF8B5CF6)
                            ],
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.add,
                            color: Colors.black, size: 18),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      "${item.quantity}",
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    GestureDetector(
                      onTap: () => Cart.decrement(index),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: Colors.white.withOpacity(0.15)),
                        ),
                        child: const Icon(Icons.remove,
                            color: Colors.white54, size: 18),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _itemImagePlaceholder() {
    return Container(
      width: 58,
      height: 58,
      color: const Color(0xFF0F1923),
      child: const Icon(Icons.shopping_bag_outlined,
          color: Colors.white12, size: 28),
    );
  }

  Widget _buildTotalBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1117),
        border: Border(
          top: BorderSide(color: Colors.white.withOpacity(0.06)),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 20,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Totals row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Total",
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.5),
                        fontSize: 12),
                  ),
                  Text(
                    "${Cart.totalUSDT.toStringAsFixed(2)} USDT",
                    style: const TextStyle(
                      color: Color(0xFF00D4FF),
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    "≈ ${Cart.totalDZD.toStringAsFixed(0)} DZD",
                    style: const TextStyle(
                        color: Color(0xFF8B5CF6), fontSize: 13),
                  ),
                ],
              ),
              Text(
                "${Cart.items.fold(0, (s, i) => s + i.quantity)} art.",
                style: const TextStyle(color: Colors.white38, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // QR Button
          GestureDetector(
            onTap: _showQrDialog,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
                ),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.qr_code_2, color: Colors.black, size: 26),
                  SizedBox(width: 10),
                  Text(
                    "Générer QR Code",
                    style: TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                      fontSize: 17,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================
// ECRAN HISTORIQUE
// ============================================
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0D1117), Color(0xFF0F1923)],
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: const Text(
            "Historique",
            style: TextStyle(color: Colors.white),
          ),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.history, size: 80, color: Colors.white.withOpacity(0.2)),
              const SizedBox(height: 20),
              Text(
                "Aucun historique",
                style: TextStyle(
                  color: Colors.white.withOpacity(0.4),
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                "Vos commandes apparaîtront ici",
                style: TextStyle(
                  color: Colors.white.withOpacity(0.2),
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================
// ECRAN DÉTAIL PRODUIT
// ============================================
class ProductDetailScreen extends StatefulWidget {
  final String productName;
  final String productImage;
  final double priceUSD;
  final double priceUSDT;
  final double priceDZD;
  final String productUrl;

  const ProductDetailScreen({
    super.key,
    required this.productName,
    required this.productImage,
    required this.priceUSD,
    required this.priceUSDT,
    required this.priceDZD,
    required this.productUrl,
  });

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen>
    with SingleTickerProviderStateMixin {
  bool _addedToCart = false;
  late AnimationController _btnController;
  late Animation<double> _btnScale;

  // Variant state
  bool _variantsLoading = false;
  List<VariantSku> _variants = [];
  List<VariantProperty> _properties = []; // all prop dimensions from API
  // "$propName::$value" → thumbnail image URL (for colour swatches)
  final Map<String, String?> _valueImages = {};
  // propName → currently-selected value
  final Map<String, String> _selections = {};
  late double _currentPriceUSD;
  late double _currentPriceUSDT;
  late double _currentPriceDZD;
  // IDs for QR / purchase backend
  String _productId = '0';   // numeric AliExpress product ID
  String _currentSkuId = '0'; // skuId of the currently selected variant

  // Currently displayed main image (changes when user taps a colour swatch)
  late String _displayImage;

  // Prop names that AliExpress uses for the colour dimension
  static const _colorPropNames = {
    'Color', 'color', 'Colour', 'colour', 'Couleur',
  };

  @override
  void initState() {
    super.initState();
    _currentPriceUSD  = widget.priceUSD;
    _currentPriceUSDT = widget.priceUSDT;
    _currentPriceDZD  = widget.priceDZD;
    _displayImage = widget.productImage;

    // Extract numeric product ID from the AliExpress URL (e.g. /item/1005005012345678.html)
    final idMatch = RegExp(r'/item/(\d+)').firstMatch(widget.productUrl);
    _productId = idMatch?.group(1) ?? '0';

    _btnController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
      lowerBound: 0.93,
      upperBound: 1.0,
      value: 1.0,
    );
    _btnScale = _btnController;

    if (widget.productUrl.isNotEmpty) _loadVariants();
  }

  @override
  void dispose() {
    _btnController.dispose();
    super.dispose();
  }

  bool _isColorProp(String name) => _colorPropNames.contains(name);

  Future<void> _loadVariants() async {
    setState(() => _variantsLoading = true);
    try {
      final response = await http
          .get(Uri.parse(
              'http://$VPS_SERVER_IP:3000/variants?url=${Uri.encodeComponent(widget.productUrl)}'))
          .timeout(const Duration(seconds: 20));

      if (!mounted) return;
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final variantList = (data['variants'] as List<dynamic>? ?? [])
            .map((v) => VariantSku.fromJson(v as Map<String, dynamic>))
            .toList();

        // Use the 'properties' array — it contains ALL AliExpress prop names
        // (Color, Shoe Size, EU Size, Size, etc.) in display order.
        final rawProps = data['properties'] as List<dynamic>? ?? [];
        final properties = rawProps
            .map((p) {
              final m = p as Map<String, dynamic>;
              return VariantProperty(
                name: m['name'] as String? ?? '',
                values: List<String>.from(m['values'] as List? ?? []),
              );
            })
            .where((p) => p.name.isNotEmpty && p.values.isNotEmpty)
            .toList();

        // Build image map for every prop value that has a thumbnail
        final valueImages = <String, String?>{};
        for (final sku in variantList) {
          for (final entry in sku.props.entries) {
            final key = '${entry.key}::${entry.value.value}';
            valueImages.putIfAbsent(key, () => entry.value.image);
          }
        }

        // Auto-select the first value for each property
        final selections = <String, String>{};
        for (final prop in properties) {
          if (prop.values.isNotEmpty) selections[prop.name] = prop.values.first;
        }

        setState(() {
          _variants   = variantList;
          _properties = properties;
          _valueImages.addAll(valueImages);
          _selections.addAll(selections);
          _syncPrice();
        });
      }
    } catch (_) {
      // Silently skip — selector stays hidden on any error
    } finally {
      if (mounted) setState(() => _variantsLoading = false);
    }
  }

  /// Match the current _selections against the SKU list and update price fields.
  /// Must be called inside setState (or before setState finishes).
  void _syncPrice() {
    if (_variants.isEmpty) return;
    final match = _variants.firstWhere(
      // A SKU matches when every selected prop value matches its props map
      (v) => _selections.entries.every(
        (e) => v.props[e.key]?.value == e.value,
      ),
      orElse: () => _variants.first,
    );
    if (match.priceUSD > 0) {
      _currentPriceUSD  = match.priceUSD;
      _currentPriceUSDT = match.priceUSD * 1.10;
      _currentPriceDZD  = _currentPriceUSDT * EXCHANGE_RATE;
    }
    _currentSkuId = match.skuId ?? '0';
  }

  bool get _hasVariants => _variants.isNotEmpty;

  void _addToCart() async {
    await _btnController.reverse();
    await _btnController.forward();

    // All selected prop values go into the cart item name, in property order
    final parts = _properties
        .map((p) => _selections[p.name])
        .whereType<String>()
        .toList();
    final name = parts.isEmpty
        ? widget.productName
        : '${widget.productName} (${parts.join(' / ')})';

    Cart.add(CartItem(
      name: name,
      image: widget.productImage,
      priceUSD: _currentPriceUSD,
      productId: _productId,
      variantId: _currentSkuId,
    ));

    setState(() => _addedToCart = true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.check_circle, color: Color(0xFF00D4FF)),
            SizedBox(width: 10),
            Text("Ajouté au panier !", style: TextStyle(color: Colors.white)),
          ],
        ),
        backgroundColor: const Color(0xFF0F1923),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 320,
            pinned: true,
            backgroundColor: const Color(0xFF0D1117),
            leading: GestureDetector(
              onTap: () => Navigator.pop(context, {
                    ...Map<String, String>.from(_selections),
                    '__productId__': _productId,
                    '__skuId__': _currentSkuId,
                  }),
              child: Container(
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.arrow_back, color: Colors.white),
              ),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: _displayImage.isNotEmpty
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 280),
                          child: Image.network(
                            _displayImage,
                            key: ValueKey(_displayImage),
                            fit: BoxFit.cover,
                            width: double.infinity,
                            height: double.infinity,
                            errorBuilder: (_, __, ___) => _imagePlaceholder(),
                          ),
                        ),
                        Positioned(
                          bottom: 0, left: 0, right: 0, height: 120,
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                colors: [const Color(0xFF0D1117), Colors.transparent],
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  : _imagePlaceholder(),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.productName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      height: 1.4,
                    ),
                  ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.1),
                  const SizedBox(height: 20),

                  // ── Variant selector ──────────────────────────────
                  if (_variantsLoading)
                    _buildVariantShimmer()
                  else if (_hasVariants) ...[
                    _buildVariantSelector(),
                    const SizedBox(height: 20),
                  ],

                  // ── Price card ───────────────────────────────────
                  Container(
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF0F1923), Color(0xFF0D1117)],
                      ),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: Colors.white.withOpacity(0.08)),
                    ),
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        _buildPriceRow(
                          icon: Icons.attach_money,
                          iconColor: Colors.white54,
                          label: "Prix USD",
                          value: "\$${_currentPriceUSD.toStringAsFixed(2)}",
                          valueColor: Colors.white70,
                          fontSize: 16,
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 14),
                          child: Divider(color: Colors.white10, height: 1),
                        ),
                        _buildPriceRow(
                          icon: Icons.currency_bitcoin,
                          iconColor: const Color(0xFF26A17B),
                          label: "USDT",
                          value: "${_currentPriceUSDT.toStringAsFixed(2)} USDT",
                          valueColor: const Color(0xFF26A17B),
                          fontSize: 22,
                          bold: true,
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 14),
                          child: Divider(color: Colors.white10, height: 1),
                        ),
                        _buildPriceRow(
                          icon: Icons.flag_rounded,
                          iconColor: const Color(0xFF006233),
                          label: "DZD",
                          value: "~ ${_currentPriceDZD.toStringAsFixed(0)} دج",
                          valueColor: const Color(0xFF8B5CF6),
                          fontSize: 22,
                          bold: true,
                        ),
                      ],
                    ),
                  ).animate().fadeIn(duration: 500.ms, delay: 100.ms).slideY(begin: 0.15),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Icon(Icons.info_outline, size: 13, color: Colors.white24),
                      const SizedBox(width: 6),
                      Text(
                        "Taux indicatif · 1 USDT = $EXCHANGE_RATE DZD",
                        style: const TextStyle(color: Colors.white24, fontSize: 12),
                      ),
                    ],
                  ).animate().fadeIn(duration: 400.ms, delay: 200.ms),
                ],
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        decoration: BoxDecoration(
          color: const Color(0xFF0D1117),
          border: Border(top: BorderSide(color: Colors.white.withOpacity(0.06))),
        ),
        child: ScaleTransition(
          scale: _btnScale,
          child: GestureDetector(
            onTap: _addedToCart ? null : _addToCart,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              height: 58,
              decoration: BoxDecoration(
                gradient: _addedToCart
                    ? const LinearGradient(colors: [Color(0xFF0F1923), Color(0xFF0F1923)])
                    : const LinearGradient(colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)]),
                borderRadius: BorderRadius.circular(18),
                border: _addedToCart
                    ? Border.all(color: const Color(0xFF00D4FF), width: 1.5)
                    : null,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _addedToCart ? Icons.check_circle_rounded : Icons.shopping_cart_rounded,
                    color: _addedToCart ? const Color(0xFF00D4FF) : Colors.black,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _addedToCart ? "Ajouté au panier" : "Ajouter au panier",
                    style: TextStyle(
                      color: _addedToCart ? const Color(0xFF00D4FF) : Colors.black,
                      fontWeight: FontWeight.bold,
                      fontSize: 17,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVariantShimmer() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 16, height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00D4FF)),
          ),
          const SizedBox(width: 12),
          Text(
            "Chargement des variantes...",
            style: TextStyle(color: Colors.white.withOpacity(0.35), fontSize: 13),
          ),
        ],
      ),
    );
  }

  /// Renders one property section (header + swatches or chips).
  Widget _buildPropertySection(VariantProperty prop, bool isFirst) {
    final isColor    = _isColorProp(prop.name);
    final selectedVal = _selections[prop.name];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!isFirst) const SizedBox(height: 16),
        // ── Section header ──────────────────────────────────────
        Row(
          children: [
            Icon(
              isColor ? Icons.palette_outlined : Icons.straighten_outlined,
              size: 14,
              color: const Color(0xFF00D4FF),
            ),
            const SizedBox(width: 6),
            Text(
              prop.name,
              style: TextStyle(
                color: Colors.white.withOpacity(0.65),
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
            if (selectedVal != null) ...[
              const SizedBox(width: 8),
              Text(
                selectedVal,
                style: const TextStyle(
                  color: Color(0xFF00D4FF),
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        // ── Values ──────────────────────────────────────────────
        if (isColor)
          _buildColorSwatches(prop)
        else
          _buildSizeChips(prop),
      ],
    );
  }

  Widget _buildColorSwatches(VariantProperty prop) {
    return SizedBox(
      height: 76,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: prop.values.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final val      = prop.values[i];
          final img      = _valueImages['${prop.name}::$val'];
          final selected = _selections[prop.name] == val;
          return GestureDetector(
            onTap: () => setState(() {
              _selections[prop.name] = val;
              _addedToCart = false;
              _syncPrice();
              // Update the hero image to the tapped colour's thumbnail
              final variantImg = _valueImages['${prop.name}::$val'];
              if (variantImg != null && variantImg.isNotEmpty) {
                _displayImage = variantImg;
              }
            }),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 66,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: selected
                      ? const Color(0xFF00D4FF)
                      : Colors.white.withOpacity(0.12),
                  width: selected ? 2 : 1,
                ),
                boxShadow: selected
                    ? [BoxShadow(
                        color: const Color(0xFF00D4FF).withOpacity(0.30),
                        blurRadius: 10,
                        spreadRadius: 1,
                      )]
                    : null,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Column(
                  children: [
                    Expanded(
                      child: img != null
                          ? Image.network(
                              img,
                              fit: BoxFit.cover,
                              width: double.infinity,
                              errorBuilder: (_, __, ___) => _colorFallback(val, selected),
                            )
                          : _colorFallback(val, selected),
                    ),
                    Container(
                      width: double.infinity,
                      color: selected
                          ? const Color(0xFF00D4FF).withOpacity(0.15)
                          : Colors.white.withOpacity(0.04),
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Text(
                        val.length > 7 ? '${val.substring(0, 6)}…' : val,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: selected ? const Color(0xFF00D4FF) : Colors.white54,
                          fontSize: 9,
                          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSizeChips(VariantProperty prop) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: prop.values.map((val) {
        final selected = _selections[prop.name] == val;
        return GestureDetector(
          onTap: () => setState(() {
            _selections[prop.name] = val;
            _addedToCart = false;
            _syncPrice();
          }),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
            decoration: BoxDecoration(
              gradient: selected
                  ? const LinearGradient(
                      colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)])
                  : null,
              color: selected ? null : Colors.white.withOpacity(0.06),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected
                    ? Colors.transparent
                    : Colors.white.withOpacity(0.12),
              ),
            ),
            child: Text(
              val,
              style: TextStyle(
                color: selected ? Colors.black : Colors.white70,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                fontSize: 13,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildVariantSelector() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < _properties.length; i++)
            _buildPropertySection(_properties[i], i == 0),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.08);
  }

  Widget _colorFallback(String name, bool selected) {
    return Container(
      color: Colors.white.withOpacity(0.05),
      child: Center(
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : '?',
          style: TextStyle(
            color: selected ? const Color(0xFF00D4FF) : Colors.white38,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildPriceRow({
    required IconData icon,
    required Color iconColor,
    required String label,
    required String value,
    required Color valueColor,
    required double fontSize,
    bool bold = false,
  }) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: iconColor.withOpacity(0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: iconColor, size: 18),
        ),
        const SizedBox(width: 14),
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 14)),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            color: valueColor,
            fontSize: fontSize,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ],
    );
  }

  Widget _imagePlaceholder() {
    return Container(
      color: const Color(0xFF0F1923),
      child: const Center(
        child: Icon(Icons.shopping_bag_outlined, size: 80, color: Colors.white12),
      ),
    );
  }
}

// ============================================
// ECRAN PROFIL
// ============================================
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _addressCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl    = TextEditingController(text: UserProfile.name);
    _phoneCtrl   = TextEditingController(text: UserProfile.phone);
    _emailCtrl   = TextEditingController(text: UserProfile.email);
    _addressCtrl = TextEditingController(text: UserProfile.address);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _addressCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    UserProfile.name = _nameCtrl.text.trim();
    UserProfile.phone = _phoneCtrl.text.trim();
    UserProfile.email = _emailCtrl.text.trim();
    UserProfile.address = _addressCtrl.text.trim();
    await UserProfile.save();
    setState(() => _saving = false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(children: [
          Icon(Icons.check_circle, color: Color(0xFF00D4FF)),
          SizedBox(width: 10),
          Text('Profil enregistré !', style: TextStyle(color: Colors.white)),
        ]),
        backgroundColor: const Color(0xFF0F1923),
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0D1117), Color(0xFF0F1923)],
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child:
                    const Icon(Icons.person_rounded, color: Colors.black),
              ),
              const SizedBox(width: 12),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Mon Profil',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold)),
                  Text('Informations personnelles',
                      style:
                          TextStyle(color: Color(0xFF00D4FF), fontSize: 11)),
                ],
              ),
            ],
          ),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          child: Form(
            key: _formKey,
            child: Column(
              children: [
                // Avatar
                Container(
                  width: 90,
                  height: 90,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
                    ),
                  ),
                  child: Center(
                    child: Text(
                      UserProfile.name.isNotEmpty
                          ? UserProfile.name[0].toUpperCase()
                          : '?',
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 38,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ).animate().scale(duration: 500.ms),

                _buildField(
                  controller: _nameCtrl,
                  label: 'Nom complet',
                  hint: 'Ex: Ahmed Benali',
                  icon: Icons.person_outline,
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Le nom est requis'
                      : null,
                ),
                const SizedBox(height: 16),
                _buildField(
                  controller: _phoneCtrl,
                  label: 'Numéro de téléphone',
                  hint: 'Ex: 0555 123 456',
                  icon: Icons.phone_outlined,
                  keyboardType: TextInputType.phone,
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Le téléphone est requis'
                      : null,
                ),
                const SizedBox(height: 16),
                _buildField(
                  controller: _emailCtrl,
                  label: 'Email (optionnel)',
                  hint: 'Ex: ahmed@email.com',
                  icon: Icons.email_outlined,
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 16),
                _buildField(
                  controller: _addressCtrl,
                  label: 'Adresse de livraison',
                  hint: 'Ex: Rue des Martyrs, Alger',
                  icon: Icons.location_on_outlined,
                  maxLines: 2,
                ),
                const SizedBox(height: 32),

                // Info banner
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00D4FF).withOpacity(0.08),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: const Color(0xFF00D4FF).withOpacity(0.2)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.qr_code_2,
                          color: Color(0xFF00D4FF), size: 20),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Votre nom et téléphone seront intégrés dans le QR code afin que l\'agent identifie votre commande.',
                          style: TextStyle(
                              color: Colors.white54, fontSize: 12, height: 1.5),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),

                // Save button
                SizedBox(
                  width: double.infinity,
                  child: GestureDetector(
                    onTap: _saving ? null : _save,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
                        ),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: _saving
                          ? const Center(
                              child: SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.black,
                                ),
                              ),
                            )
                          : const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.save_rounded,
                                    color: Colors.black, size: 22),
                                SizedBox(width: 10),
                                Text(
                                  'Enregistrer le profil',
                                  style: TextStyle(
                                    color: Colors.black,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 17,
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                ).animate().fadeIn(duration: 400.ms, delay: 200.ms),

                const SizedBox(height: 16),
                GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AgentScreen()),
                  ),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: const Color(0xFF00D4FF).withOpacity(0.4)),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.qr_code_scanner_rounded,
                            color: Color(0xFF00D4FF), size: 20),
                        SizedBox(width: 10),
                        Text(
                          'Mode Agent',
                          style: TextStyle(
                            color: Color(0xFF00D4FF),
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
                ).animate().fadeIn(duration: 400.ms, delay: 300.ms),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    TextInputType keyboardType = TextInputType.text,
    int maxLines = 1,
    String? Function(String?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          keyboardType: keyboardType,
          maxLines: maxLines,
          validator: validator,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
            filled: true,
            fillColor: Colors.white.withOpacity(0.06),
            prefixIcon: Icon(icon, color: const Color(0xFF00D4FF), size: 20),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide:
                  BorderSide(color: Colors.white.withOpacity(0.08)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFF00D4FF)),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide:
                  const BorderSide(color: Colors.redAccent, width: 1.5),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide:
                  const BorderSide(color: Colors.redAccent, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================
// AGENT SCREEN — QR scanner + payment confirm
// ============================================

class _OrderScan {
  final String orderId;
  final double totalUsdt;
  double get totalDzd => totalUsdt * EXCHANGE_RATE;

  const _OrderScan({required this.orderId, required this.totalUsdt});

  /// Parse `NP|ORDER_ID|TOTAL_USDT|...` (items segment is ignored by agent).
  static _OrderScan? tryParse(String raw) {
    final parts = raw.split('|');
    if (parts.length < 3 || parts[0] != 'NP') return null;
    final usdt = double.tryParse(parts[2]);
    if (usdt == null) return null;
    return _OrderScan(orderId: parts[1], totalUsdt: usdt);
  }
}

class AgentScreen extends StatefulWidget {
  const AgentScreen({super.key});

  @override
  State<AgentScreen> createState() => _AgentScreenState();
}

class _AgentScreenState extends State<AgentScreen> {
  final TextEditingController _inputCtrl = TextEditingController();

  _OrderScan? _order;
  bool _confirming = false;
  bool _confirmed = false;
  String? _error;

  @override
  void dispose() {
    _inputCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final raw = _inputCtrl.text.trim();
    if (raw.isEmpty) return;
    final parsed = _OrderScan.tryParse(raw);
    if (parsed != null) {
      setState(() { _order = parsed; _error = null; });
    } else {
      setState(() => _error = 'Format invalide. Collez le texte complet du QR.');
    }
  }

  Future<void> _confirmPayment() async {
    if (_order == null) return;
    setState(() { _confirming = true; _error = null; });
    try {
      final resp = await http.post(
        Uri.parse('http://$VPS_SERVER_IP:3000/payment-confirmed'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'orderId': _order!.orderId,
          'totalUsdt': _order!.totalUsdt,
          'totalDzd': _order!.totalDzd,
          'confirmedAt': DateTime.now().toIso8601String(),
        }),
      ).timeout(const Duration(seconds: 15));

      if (resp.statusCode == 200 || resp.statusCode == 201) {
        setState(() { _confirmed = true; _confirming = false; });
      } else {
        setState(() {
          _error = 'Erreur serveur (${resp.statusCode})';
          _confirming = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Impossible de joindre le serveur';
        _confirming = false;
      });
    }
  }

  void _reset() {
    _inputCtrl.clear();
    setState(() { _order = null; _confirmed = false; _error = null; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F1923),
        foregroundColor: Colors.white,
        title: const Text('Mode Agent',
            style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        elevation: 0,
      ),
      body: _order == null ? _buildInput() : _buildOrderCard(),
    );
  }

  Widget _buildInput() {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 32),
          const Icon(Icons.assignment_outlined,
              color: Color(0xFF00D4FF), size: 48),
          const SizedBox(height: 20),
          const Text(
            'ENTRER L\'ID DE COMMANDE',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white54,
              fontSize: 12,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 28),
          TextField(
            controller: _inputCtrl,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Collez le texte du QR (NP|ID|total|…)',
              hintStyle: const TextStyle(color: Colors.white30),
              filled: true,
              fillColor: const Color(0xFF1A2332),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFF00D4FF)),
              ),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 18, vertical: 16),
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
          ],
          const SizedBox(height: 20),
          GestureDetector(
            onTap: _submit,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.search_rounded, color: Colors.black, size: 20),
                  SizedBox(width: 8),
                  Text(
                    'Rechercher la commande',
                    style: TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOrderCard() {
    final order = _order!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 20),
          // Success check or confirmation header
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF00D4FF).withOpacity(0.4),
                  blurRadius: 24,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: const Icon(Icons.assignment_turned_in_rounded,
                color: Colors.black, size: 36),
          ),
          const SizedBox(height: 20),
          Text(
            'Commande ${order.orderId}',
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 13,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 32),
          // Amount card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF00D4FF).withOpacity(0.12),
                  const Color(0xFF8B5CF6).withOpacity(0.08),
                ],
              ),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                  color: const Color(0xFF00D4FF).withOpacity(0.25)),
            ),
            child: Column(
              children: [
                const Text(
                  'MONTANT À ENCAISSER',
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 11,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  '${order.totalUsdt.toStringAsFixed(2)} USDT',
                  style: const TextStyle(
                    color: Color(0xFF00D4FF),
                    fontSize: 38,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '≈ ${order.totalDzd.toStringAsFixed(0)} DZD',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 18,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),

          if (_confirmed) ...[
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFF00FF88).withOpacity(0.1),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: const Color(0xFF00FF88).withOpacity(0.3)),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.check_circle_rounded,
                      color: Color(0xFF00FF88), size: 22),
                  SizedBox(width: 10),
                  Text(
                    'Paiement confirmé',
                    style: TextStyle(
                      color: Color(0xFF00FF88),
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            TextButton.icon(
              onPressed: _reset,
              icon: const Icon(Icons.add_circle_outline_rounded,
                  color: Color(0xFF00D4FF)),
              label: const Text('Nouvelle commande',
                  style: TextStyle(color: Color(0xFF00D4FF))),
            ),
          ] else ...[
            if (_error != null) ...[
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.red.withOpacity(0.3)),
                ),
                child: Text(_error!,
                    style: const TextStyle(color: Colors.redAccent)),
              ),
              const SizedBox(height: 16),
            ],
            // Confirm button
            GestureDetector(
              onTap: _confirming ? null : _confirmPayment,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 18),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF00D4FF), Color(0xFF8B5CF6)],
                  ),
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF00D4FF).withOpacity(0.3),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: _confirming
                    ? const Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.5, color: Colors.black),
                        ),
                      )
                    : const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.check_rounded,
                              color: Colors.black, size: 22),
                          SizedBox(width: 10),
                          Text(
                            'Confirmer paiement reçu',
                            style: TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: _reset,
              child: const Text('Annuler',
                  style: TextStyle(color: Colors.white38)),
            ),
          ],
        ],
      ),
    );
  }
}


// ============================================
// CIRCUIT BOARD FLAG — CustomPaint
// ============================================
//
// Animated PCB-style flag: dark green substrate, glowing copper traces,
// solder pads, two IC chips, and traveling signal electrons.
// `phase` (0 → 2π) drives all animations.
class CircuitBoardFlagPainter extends CustomPainter {
  final double phase;
  final bool isMini;

  CircuitBoardFlagPainter(this.phase, {this.isMini = false});

  // Normalised [x1,y1, x2,y2] trace segments (0..1)
  static const List<List<double>> _segs = [
    // ── Horizontals ──
    [0.00, 0.17, 1.00, 0.17],
    [0.00, 0.50, 0.42, 0.50],
    [0.58, 0.50, 1.00, 0.50],
    [0.00, 0.83, 1.00, 0.83],
    [0.15, 0.33, 0.50, 0.33],
    [0.50, 0.67, 0.85, 0.67],
    [0.25, 0.17, 0.25, 0.33],  // short V
    [0.75, 0.67, 0.75, 0.83],  // short V
    // ── Verticals ──
    [0.15, 0.00, 0.15, 1.00],
    [0.85, 0.00, 0.85, 1.00],
    [0.50, 0.00, 0.50, 0.33],
    [0.50, 0.67, 0.50, 1.00],
    [0.35, 0.17, 0.35, 0.83],
    [0.65, 0.17, 0.65, 0.83],
  ];

  // Normalised pad positions [x,y]
  static const List<List<double>> _pads = [
    [0.15, 0.17], [0.35, 0.17], [0.65, 0.17], [0.85, 0.17],
    [0.15, 0.33], [0.25, 0.33], [0.50, 0.33],
    [0.15, 0.50], [0.85, 0.50],
    [0.50, 0.67], [0.75, 0.67], [0.85, 0.67],
    [0.15, 0.83], [0.35, 0.83], [0.65, 0.83], [0.85, 0.83],
  ];

  // Two signal electron paths (list of [x,y] waypoints, normalised)
  static const List<List<List<double>>> _signalPaths = [
    // path A — top-left loop
    [[0.00, 0.17], [0.15, 0.17], [0.15, 0.33], [0.25, 0.33],
     [0.25, 0.17], [0.50, 0.17], [0.50, 0.33], [0.35, 0.33],
     [0.35, 0.83], [0.15, 0.83], [0.15, 0.50], [0.00, 0.50]],
    // path B — right side
    [[1.00, 0.17], [0.85, 0.17], [0.85, 0.50], [0.65, 0.50],
     [0.65, 0.67], [0.75, 0.67], [0.75, 0.83], [0.85, 0.83],
     [0.85, 1.00]],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // ── 1. PCB substrate ───────────────────────────────────────────────
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h),
      Paint()..color = const Color(0xFF061206),
    );

    // Subtle grid (full size only)
    if (!isMini) {
      final gridPaint = Paint()
        ..color = const Color(0xFF00FF88).withOpacity(0.05)
        ..strokeWidth = 0.4;
      for (double x = 0; x <= w; x += w * 0.1) {
        canvas.drawLine(Offset(x, 0), Offset(x, h), gridPaint);
      }
      for (double y = 0; y <= h; y += h * 0.1) {
        canvas.drawLine(Offset(0, y), Offset(w, y), gridPaint);
      }
    }

    // ── 2. Pulsing glow factor ─────────────────────────────────────────
    final glow  = (sin(phase * 1.4) + 1) * 0.5;      // 0..1
    final glow2 = (sin(phase * 0.9 + 1.2) + 1) * 0.5; // offset pulse

    // ── 3. Traces ──────────────────────────────────────────────────────
    final traceAlpha = 0.40 + glow * 0.40;
    final traceW = isMini ? 0.7 : 1.4;

    final traceGlowPaint = Paint()
      ..color = const Color(0xFF00FF88).withOpacity(traceAlpha * 0.35)
      ..strokeWidth = traceW * 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.5);

    final tracePaint = Paint()
      ..color = const Color(0xFF00FF88).withOpacity(traceAlpha)
      ..strokeWidth = traceW
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    for (final s in _segs) {
      final p1 = Offset(s[0] * w, s[1] * h);
      final p2 = Offset(s[2] * w, s[3] * h);
      if (!isMini) canvas.drawLine(p1, p2, traceGlowPaint);
      canvas.drawLine(p1, p2, tracePaint);
    }

    // ── 4. Solder pads ─────────────────────────────────────────────────
    final padR       = isMini ? 1.5 : 3.0;
    final padAlpha   = 0.55 + glow2 * 0.35;

    final padGlowP = Paint()
      ..color = const Color(0xFF00FF88).withOpacity(0.45)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, isMini ? 2 : 5);
    final padFillP = Paint()
      ..color = const Color(0xFF00FF88).withOpacity(padAlpha);
    final padRingP = Paint()
      ..color = const Color(0xFFAAFFCC).withOpacity(0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = isMini ? 0.4 : 0.7;

    for (final p in _pads) {
      final c = Offset(p[0] * w, p[1] * h);
      if (!isMini) canvas.drawCircle(c, padR * 2, padGlowP);
      canvas.drawCircle(c, padR, padFillP);
      canvas.drawCircle(c, padR, padRingP);
    }

    // ── 5. IC chips (two small chips, full-size only) ──────────────────
    if (!isMini) {
      _drawIC(canvas, Offset(w * 0.50, h * 0.50),
              w * 0.14, h * 0.22, glow);
      _drawIC(canvas, Offset(w * 0.50, h * 0.50),
              w * 0.14, h * 0.22, glow, secondary: true);
      // second IC, top-right area
      _drawIC(canvas, Offset(w * 0.78, h * 0.33),
              w * 0.10, h * 0.18, glow2);
    }

    // ── 6. Traveling signal electrons ─────────────────────────────────
    if (!isMini) {
      final tA = ((phase / (2 * pi)) * 1.0 % 1.0);
      final tB = ((phase / (2 * pi)) * 0.7 + 0.5) % 1.0;
      _drawSignal(canvas, w, h, _signalPaths[0], tA, const Color(0xFF00FFAA));
      _drawSignal(canvas, w, h, _signalPaths[1], tB, const Color(0xFF00D4FF));
    } else {
      // Mini: simple pulsing dot on centre trace
      final tM = (phase / (2 * pi)) % 1.0;
      final dotX = tM * w;
      final dotC = Offset(dotX, h * 0.50);
      canvas.drawCircle(dotC, 2.2,
          Paint()
            ..color = const Color(0xFF00FF88).withOpacity(0.9)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2));
      canvas.drawCircle(dotC, 1.0,
          Paint()..color = Colors.white.withOpacity(0.95));
    }
  }

  /// Draw a simplified IC chip outline with pins.
  void _drawIC(
    Canvas canvas,
    Offset center,
    double chipW,
    double chipH,
    double glow, {
    bool secondary = false,
  }) {
    if (secondary) return; // only one IC at this position

    final rect = Rect.fromCenter(center: center, width: chipW, height: chipH);
    canvas.drawRect(rect, Paint()..color = const Color(0xFF0A1F0A));
    canvas.drawRect(
      rect,
      Paint()
        ..color = const Color(0xFF00FF88).withOpacity(0.55 + glow * 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9,
    );

    // Text label "T C" in chip
    final textPainter = TextPainter(
      text: TextSpan(
        text: 'TC',
        style: TextStyle(
          color: const Color(0xFF00FF88).withOpacity(0.50 + glow * 0.40),
          fontSize: chipW * 0.28,
          fontWeight: FontWeight.bold,
          letterSpacing: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
      canvas,
      center - Offset(textPainter.width / 2, textPainter.height / 2),
    );

    // Pins (left & right, 3 per side)
    const numPins = 3;
    final pinSpacing = chipH / (numPins + 1);
    final pinLen = chipW * 0.18;
    final pinPaint = Paint()
      ..color = const Color(0xFF00FF88).withOpacity(0.55)
      ..strokeWidth = 0.8;
    for (int i = 0; i < numPins; i++) {
      final py = center.dy - chipH / 2 + pinSpacing * (i + 1);
      canvas.drawLine(
        Offset(center.dx - chipW / 2 - pinLen, py),
        Offset(center.dx - chipW / 2, py),
        pinPaint,
      );
      canvas.drawLine(
        Offset(center.dx + chipW / 2, py),
        Offset(center.dx + chipW / 2 + pinLen, py),
        pinPaint,
      );
    }
  }

  /// Draw an animated electron signal traveling along [path] at progress [t].
  void _drawSignal(
    Canvas canvas,
    double w,
    double h,
    List<List<double>> path,
    double t,
    Color color,
  ) {
    if (path.length < 2) return;

    // Build cumulative length table
    final pts = path.map((p) => Offset(p[0] * w, p[1] * h)).toList();
    final lengths = <double>[0];
    for (int i = 1; i < pts.length; i++) {
      lengths.add(lengths.last + (pts[i] - pts[i - 1]).distance);
    }
    final total = lengths.last;
    if (total == 0) return;

    // Position at progress t
    final target = t * total;
    int seg = 0;
    for (int i = 1; i < lengths.length; i++) {
      if (lengths[i] >= target) { seg = i - 1; break; }
    }
    seg = seg.clamp(0, pts.length - 2);
    final segLen  = (pts[seg + 1] - pts[seg]).distance;
    final segFrac = segLen > 0
        ? ((target - lengths[seg]) / segLen).clamp(0.0, 1.0)
        : 0.0;
    final pos = Offset.lerp(pts[seg], pts[seg + 1], segFrac)!;

    // Outer glow
    canvas.drawCircle(
      pos, 5.5,
      Paint()
        ..color = color.withOpacity(0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    // Core dot
    canvas.drawCircle(pos, 2.2,
        Paint()..color = color.withOpacity(0.95));
    // Bright centre
    canvas.drawCircle(pos, 0.8,
        Paint()..color = Colors.white.withOpacity(0.9));
  }

  @override
  bool shouldRepaint(CircuitBoardFlagPainter old) => true;
}

// ============================================
// IMPORT WEBVIEW — Temu / Shein screenshot importer
// ============================================
class ImportWebViewScreen extends StatefulWidget {
  const ImportWebViewScreen({super.key});

  @override
  State<ImportWebViewScreen> createState() => _ImportWebViewScreenState();
}

class _ImportWebViewScreenState extends State<ImportWebViewScreen> {
  late final WebViewController _controller;
  bool _loading = true;

  static const _importUrl = 'http://$VPS_SERVER_IP/import';

  // Injected after page load: watch #result for JSON and relay via FlutterBridge
  static const _bridgeJs = r'''
(function() {
  var el = document.getElementById('result');
  if (!el) return;
  var observer = new MutationObserver(function() {
    var text = el.textContent.trim();
    if (text.startsWith('{')) {
      try { JSON.parse(text); FlutterBridge.postMessage(text); } catch(e) {}
    }
  });
  observer.observe(el, { childList: true, subtree: true, characterData: true });
})();
''';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'FlutterBridge',
        onMessageReceived: (msg) {
          try {
            final data = jsonDecode(msg.message) as Map<String, dynamic>;
            if (!data.containsKey('error') && mounted) {
              Navigator.pop(context, data);
            }
          } catch (_) {}
        },
      )
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          setState(() => _loading = false);
          _controller.runJavaScript(_bridgeJs);
        },
      ))
      ..loadRequest(Uri.parse(_importUrl));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F1923),
        foregroundColor: Colors.white,
        title: const Text(
          'Importer Temu / Shein',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => _controller.reload(),
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading)
            const Center(
              child: CircularProgressIndicator(color: Color(0xFF00D4FF)),
            ),
        ],
      ),
    );
  }
}
