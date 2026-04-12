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

  CartItem({
    required this.name,
    required this.image,
    required this.priceUSD,
    this.quantity = 1,
  });

  double get lineUSDT => priceUSD * 1.25 * quantity;
  double get lineDZD => lineUSDT * EXCHANGE_RATE;
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
  }

  static void add(CartItem newItem) {
    final idx = items.indexWhere((i) => i.name == newItem.name);
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

void main() {
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
      title: 'henini',
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFF0A0E21),
        primaryColor: const Color(0xFF00FF87),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00FF87),
          brightness: Brightness.dark,
        ),
        fontFamily: 'SF Pro Display',
      ),
      home: const MainScreen(),
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
  ];

  @override
  void initState() {
    super.initState();
    Cart.addListener(_onCartChanged);
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
            colors: [Color(0xFF1A1F3D), Color(0xFF0A0E21)],
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
          selectedItemColor: const Color(0xFF00FF87),
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
      _totalUsdt = _originalPrice * 1.25;
      _totalDzd = _totalUsdt * EXCHANGE_RATE;
      _orderID = "TC-${Random().nextInt(9000) + 1000}";
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
          backgroundColor: const Color(0xFF1A1F3D),
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
                        const Color(0xFF00FF87).withOpacity(0.1),
                        const Color(0xFF60EFFF).withOpacity(0.1),
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
                          _buildMiniAlgerianFlag(),
                          const SizedBox(width: 10),
                          const Text(
                            "TCHIPA PAY",
                            style: TextStyle(
                              color: Color(0xFF00FF87),
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
                          data:
                              "TCHIPA|$_orderID|${_totalUsdt.toStringAsFixed(2)}|USDT",
                          version: QrVersions.auto,
                          size: 180,
                          eyeStyle: const QrEyeStyle(
                            eyeShape: QrEyeShape.square,
                            color: Color(0xFF00FF87),
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
                          color: Color(0xFF00FF87),
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
                backgroundColor: const Color(0xFF00FF87),
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
            'TchipaPay - Commande $_orderID - ${_totalUsdt.toStringAsFixed(2)} USDT',
      );
    }
  }

  void _showToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: const Color(0xFF1A1F3D),
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
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
              Color(0xFF0A0E21),
              Color(0xFF1A1F3D),
              Color(0xFF0A0E21),
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
        SizedBox(
          height: 60,
          width: 90,
          child: AnimatedBuilder(
            animation: _flagAnimation,
            builder: (context, child) {
              return CustomPaint(
                painter: AlgerianFlagPainter(_flagAnimation.value),
              );
            },
          ),
        ).animate().fadeIn(duration: 600.ms).slideY(begin: -0.3),
        const SizedBox(height: 15),
        ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            colors: [Color(0xFF00FF87), Color(0xFF60EFFF)],
          ).createShader(bounds),
          child: const Text(
            "TCHIPA",
            style: TextStyle(
              fontSize: 42,
              fontWeight: FontWeight.bold,
              color: Colors.white,
              letterSpacing: 4,
            ),
          ),
        ).animate().fadeIn(duration: 800.ms, delay: 200.ms),
        const SizedBox(height: 5),
        Text(
          "Vérificateur de produits AliExpress & Temu",
          style: TextStyle(
            color: Colors.white.withOpacity(0.6),
            fontSize: 14,
          ),
        ).animate().fadeIn(duration: 800.ms, delay: 400.ms),
      ],
    );
  }

  Widget _buildMiniAlgerianFlag() {
    return SizedBox(
      height: 20,
      width: 30,
      child: AnimatedBuilder(
        animation: _flagAnimation,
        builder: (context, child) {
          return CustomPaint(
            painter: AlgerianFlagPainter(_flagAnimation.value, isMini: true),
          );
        },
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
              prefixIcon: const Icon(Icons.link, color: Color(0xFF00FF87)),
              suffixIcon: _isLoading
                  ? Container(
                      width: 20,
                      height: 20,
                      margin: const EdgeInsets.all(12),
                      child: const CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF00FF87),
                      ),
                    )
                  : IconButton(
                      icon: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF00FF87), Color(0xFF60EFFF)],
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
                  const Icon(Icons.attach_money, color: Color(0xFF00FF87)),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 600.ms, delay: 600.ms).slideY(begin: 0.2);
  }

  Widget _buildProductCard() {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ProductDetailScreen(
              productName: _productName,
              productImage: _productImage,
              priceUSD: _originalPrice,
              priceUSDT: _totalUsdt,
              priceDZD: _totalDzd,
            ),
          ),
        );
      },
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              const Color(0xFF00FF87).withOpacity(0.1),
              const Color(0xFF60EFFF).withOpacity(0.05),
            ],
          ),
          borderRadius: BorderRadius.circular(20),
          border:
              Border.all(color: const Color(0xFF00FF87).withOpacity(0.3)),
        ),
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.shopping_bag,
                    color: Color(0xFF00FF87), size: 20),
                const SizedBox(width: 8),
                const Text(
                  "Produit détecté",
                  style: TextStyle(
                    color: Color(0xFF00FF87),
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
                  colors: [Color(0xFF00FF87), Color(0xFF60EFFF)],
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
                const Color(0xFF00FF87).withOpacity(0.15),
                const Color(0xFF60EFFF).withOpacity(0.1),
              ],
            ),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(
                color: const Color(0xFF00FF87).withOpacity(0.3)),
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
                                color: const Color(0xFF00FF87),
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
                                color: Color(0xFF00FF87),
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
                      color: Color(0xFF00FF87),
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
                      color: Color(0xFF60EFFF),
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
                  colors: [Color(0xFF00FF87), Color(0xFF60EFFF)],
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
    _orderID = "TC-${Random().nextInt(9000) + 1000}";
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
          backgroundColor: const Color(0xFF1A1F3D),
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }

    _orderID = "TC-${Random().nextInt(9000) + 1000}";

    showDialog(
      context: context,
      builder: (context) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: AlertDialog(
          backgroundColor: const Color(0xFF1A1F3D),
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
                      const Color(0xFF00FF87).withOpacity(0.1),
                      const Color(0xFF60EFFF).withOpacity(0.1),
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
                      "TCHIPA PAY",
                      style: TextStyle(
                        color: Color(0xFF00FF87),
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
                        data:
                            "TCHIPA|$_orderID|${Cart.totalUSDT.toStringAsFixed(2)}|USDT|${Cart.items.length}items",
                        version: QrVersions.auto,
                        size: 200,
                        eyeStyle: const QrEyeStyle(
                          eyeShape: QrEyeShape.square,
                          color: Color(0xFF00FF87),
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
                                    color: Color(0xFF00FF87),
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
                        color: Color(0xFF00FF87),
                      ),
                    ),
                    // Total DZD
                    Text(
                      "≈ ${Cart.totalDZD.toStringAsFixed(0)} DZD",
                      style: const TextStyle(
                          color: Color(0xFF60EFFF), fontSize: 15),
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
                        'TchipaPay - Commande $_orderID - ${Cart.totalUSDT.toStringAsFixed(2)} USDT',
                  );
                }
              },
              icon: const Icon(Icons.share),
              label: const Text("Partager"),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00FF87),
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
          colors: [Color(0xFF0A0E21), Color(0xFF1A1F3D)],
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
                    colors: [Color(0xFF00FF87), Color(0xFF60EFFF)],
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
                        color: Color(0xFF00FF87), fontSize: 11),
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
                  const Color(0xFF00FF87).withOpacity(0.15),
                  const Color(0xFF60EFFF).withOpacity(0.1),
                ],
              ),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.shopping_cart_outlined,
              size: 56,
              color: Color(0xFF00FF87),
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
                          color: Color(0xFF00FF87),
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        "≈ ${item.lineDZD.toStringAsFixed(0)} DZD",
                        style: const TextStyle(
                            color: Color(0xFF60EFFF), fontSize: 11),
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
                      )),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [
                              Color(0xFF00FF87),
                              Color(0xFF60EFFF)
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
      color: const Color(0xFF1A1F3D),
      child: const Icon(Icons.shopping_bag_outlined,
          color: Colors.white12, size: 28),
    );
  }

  Widget _buildTotalBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0E21),
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
                      color: Color(0xFF00FF87),
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    "≈ ${Cart.totalDZD.toStringAsFixed(0)} DZD",
                    style: const TextStyle(
                        color: Color(0xFF60EFFF), fontSize: 13),
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
                  colors: [Color(0xFF00FF87), Color(0xFF60EFFF)],
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
          colors: [Color(0xFF0A0E21), Color(0xFF1A1F3D)],
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

  const ProductDetailScreen({
    super.key,
    required this.productName,
    required this.productImage,
    required this.priceUSD,
    required this.priceUSDT,
    required this.priceDZD,
  });

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen>
    with SingleTickerProviderStateMixin {
  bool _addedToCart = false;
  late AnimationController _btnController;
  late Animation<double> _btnScale;

  @override
  void initState() {
    super.initState();
    _btnController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
      lowerBound: 0.93,
      upperBound: 1.0,
      value: 1.0,
    );
    _btnScale = _btnController;
  }

  @override
  void dispose() {
    _btnController.dispose();
    super.dispose();
  }

  void _addToCart() async {
    await _btnController.reverse();
    await _btnController.forward();

    Cart.add(CartItem(
      name: widget.productName,
      image: widget.productImage,
      priceUSD: widget.priceUSD,
    ));

    setState(() => _addedToCart = true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.check_circle, color: Color(0xFF00FF87)),
            SizedBox(width: 10),
            Text("Ajouté au panier !",
                style: TextStyle(color: Colors.white)),
          ],
        ),
        backgroundColor: const Color(0xFF1A1F3D),
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E21),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 320,
            pinned: true,
            backgroundColor: const Color(0xFF0A0E21),
            leading: GestureDetector(
              onTap: () => Navigator.pop(context),
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
              background: widget.productImage.isNotEmpty
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.network(
                          widget.productImage,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _imagePlaceholder(),
                        ),
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          height: 120,
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                colors: [
                                  const Color(0xFF0A0E21),
                                  Colors.transparent,
                                ],
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
                  const SizedBox(height: 24),
                  Container(
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF1A1F3D), Color(0xFF0A0E21)],
                      ),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                          color: Colors.white.withOpacity(0.08)),
                    ),
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        _buildPriceRow(
                          icon: Icons.attach_money,
                          iconColor: Colors.white54,
                          label: "Prix USD",
                          value:
                              "\$${widget.priceUSD.toStringAsFixed(2)}",
                          valueColor: Colors.white70,
                          fontSize: 16,
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 14),
                          child:
                              Divider(color: Colors.white10, height: 1),
                        ),
                        _buildPriceRow(
                          icon: Icons.currency_bitcoin,
                          iconColor: const Color(0xFF26A17B),
                          label: "USDT",
                          value:
                              "${widget.priceUSDT.toStringAsFixed(2)} USDT",
                          valueColor: const Color(0xFF26A17B),
                          fontSize: 22,
                          bold: true,
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 14),
                          child:
                              Divider(color: Colors.white10, height: 1),
                        ),
                        _buildPriceRow(
                          icon: Icons.flag_rounded,
                          iconColor: const Color(0xFF006233),
                          label: "DZD",
                          value:
                              "~ ${widget.priceDZD.toStringAsFixed(0)} دج",
                          valueColor: const Color(0xFF60EFFF),
                          fontSize: 22,
                          bold: true,
                        ),
                      ],
                    ),
                  ).animate().fadeIn(duration: 500.ms, delay: 100.ms).slideY(begin: 0.15),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Icon(Icons.info_outline,
                          size: 13, color: Colors.white24),
                      const SizedBox(width: 6),
                      Text(
                        "Taux indicatif · 1 USDT = $EXCHANGE_RATE DZD",
                        style: const TextStyle(
                            color: Colors.white24, fontSize: 12),
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
          color: const Color(0xFF0A0E21),
          border: Border(
              top: BorderSide(color: Colors.white.withOpacity(0.06))),
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
                    ? const LinearGradient(
                        colors: [Color(0xFF1A1F3D), Color(0xFF1A1F3D)])
                    : const LinearGradient(
                        colors: [Color(0xFF00FF87), Color(0xFF60EFFF)]),
                borderRadius: BorderRadius.circular(18),
                border: _addedToCart
                    ? Border.all(
                        color: const Color(0xFF00FF87), width: 1.5)
                    : null,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _addedToCart
                        ? Icons.check_circle_rounded
                        : Icons.shopping_cart_rounded,
                    color: _addedToCart
                        ? const Color(0xFF00FF87)
                        : Colors.black,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _addedToCart
                        ? "Ajouté au panier"
                        : "Ajouter au panier",
                    style: TextStyle(
                      color: _addedToCart
                          ? const Color(0xFF00FF87)
                          : Colors.black,
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
        Text(label,
            style: const TextStyle(color: Colors.white54, fontSize: 14)),
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
      color: const Color(0xFF1A1F3D),
      child: const Center(
        child: Icon(Icons.shopping_bag_outlined,
            size: 80, color: Colors.white12),
      ),
    );
  }
}

// ============================================
// DRAPEAU ALGÉRIEN ANIMÉ
// ============================================
class AlgerianFlagPainter extends CustomPainter {
  final double wavePhase;
  final bool isMini;

  AlgerianFlagPainter(this.wavePhase, {this.isMini = false});

  @override
  void paint(Canvas canvas, Size size) {
    final paintGreen = Paint()..color = const Color(0xFF006233);
    final paintWhite = Paint()..color = Colors.white;
    final paintRed = Paint()..color = const Color(0xFFD21034);

    final double halfWidth = size.width / 2;
    final pathGreen = Path();
    final pathWhite = Path();

    final waveAmplitude = isMini ? 1.0 : 3.0;
    final waveFrequency = 0.05;

    pathGreen.moveTo(0, 0);
    for (double x = 0; x <= halfWidth; x++) {
      final y =
          sin((x * waveFrequency) + wavePhase) * waveAmplitude;
      pathGreen.lineTo(x, y);
    }
    for (double x = halfWidth; x >= 0; x--) {
      final y = size.height +
          sin((x * waveFrequency) + wavePhase + pi) * waveAmplitude;
      pathGreen.lineTo(x, y);
    }
    pathGreen.close();
    canvas.drawPath(pathGreen, paintGreen);

    pathWhite.moveTo(halfWidth, 0);
    for (double x = halfWidth; x <= size.width; x++) {
      final y =
          sin((x * waveFrequency) + wavePhase) * waveAmplitude;
      pathWhite.lineTo(x, y);
    }
    for (double x = size.width; x >= halfWidth; x--) {
      final y = size.height +
          sin((x * waveFrequency) + wavePhase + pi) * waveAmplitude;
      pathWhite.lineTo(x, y);
    }
    pathWhite.close();
    canvas.drawPath(pathWhite, paintWhite);

    final centerX = halfWidth;
    final centerY = size.height / 2;
    final crescentRadius = isMini ? 6.0 : 18.0;
    final starRadius = isMini ? 3.0 : 10.0;

    final crescentPath = Path();
    final outerRadius = crescentRadius;
    final innerRadius = crescentRadius * 0.7;
    final crescentOffset = crescentRadius * 0.3;

    crescentPath.addOval(Rect.fromCircle(
      center: Offset(centerX + crescentOffset, centerY),
      radius: outerRadius,
    ));
    crescentPath.addOval(Rect.fromCircle(
      center: Offset(
          centerX + crescentOffset + (outerRadius - innerRadius), centerY),
      radius: innerRadius,
    ));
    crescentPath.fillType = PathFillType.evenOdd;
    canvas.drawPath(crescentPath, paintRed);

    final starPath = Path();
    const numPoints = 5;
    final outerR = starRadius;
    final innerR = starRadius * 0.4;

    for (int i = 0; i < numPoints * 2; i++) {
      final radius = i.isEven ? outerR : innerR;
      final angle = (i * pi / numPoints) - pi / 2;
      final x = centerX - crescentRadius * 0.3 + radius * cos(angle);
      final y = centerY + radius * sin(angle);
      if (i == 0) {
        starPath.moveTo(x, y);
      } else {
        starPath.lineTo(x, y);
      }
    }
    starPath.close();
    canvas.drawPath(starPath, paintRed);
  }

  @override
  bool shouldRepaint(AlgerianFlagPainter oldDelegate) => true;
}
