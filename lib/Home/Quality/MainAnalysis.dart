import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_gemini/flutter_gemini.dart';
import 'package:intl/intl.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';
import 'package:modal_bottom_sheet/modal_bottom_sheet.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watalygold/utils/gemini_rate_limiter.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:watalygold/Home/Model/Image_State.dart';
import 'package:watalygold/Home/Model/gemini_state.dart';
import 'package:watalygold/Home/Quality/WeightNumber.dart';
import 'package:watalygold/Widgets/Appbar_main.dart';
import 'package:watalygold/Widgets/Color.dart';
import 'package:watalygold/Widgets/DialogHowtoUse.dart';
import 'package:watalygold/Widgets/Quality/BottomSheetGemini.dart';
import 'package:watalygold/Widgets/WeightNumber/DialogError.dart';
import 'package:provider/provider.dart';
import 'package:watalygold/Home/Model/Model_Analysis.dart';
import 'package:watalygold/Widgets/imagestateGird.dart';

class ProblematicImage {
  final int statusimage;
  final bool isStatusMangoProblem;
  final bool isStatusMangoColorProblem;

  ProblematicImage({
    required this.statusimage,
    required this.isStatusMangoProblem,
    required this.isStatusMangoColorProblem,
  });
}

class TakePictureScreen extends StatefulWidget {
  const TakePictureScreen({
    super.key,
    required this.camera,
  });

  final List<CameraDescription> camera;

  @override
  TakePictureScreenState createState() => TakePictureScreenState();
}

class TakePictureScreenState extends State<TakePictureScreen> {
  String? result;
  final ImagePicker picker = ImagePicker();
  late CameraController _controller;
  late Future<void> _initializeControllerFuture;
  String _mobileDeviceIdentifier = "";
  int selectedIndex = 0;
  late bool checkhowtouse;
  int statusimage = 1;
  bool _noInternet = false;
  final Connectivity _connectivity = Connectivity();
  bool _isBottomSheetShown = false;

  Future<String?> getDeviceId() async {
    var deviceInfo = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
      return androidInfo.id; // Unique ID on Android
    } else if (Platform.isIOS) {
      IosDeviceInfo iosInfo = await deviceInfo.iosInfo;
      return iosInfo.identifierForVendor; // Unique ID on iOS
    }
    return null;
  }

  void _checkHowtoUse() async {
    final prefs = await SharedPreferences.getInstance();
    checkhowtouse = prefs.getBool("checkhowtouse") ?? false;
    _mobileDeviceIdentifier = prefs.getString("device") ?? "unknow";
    if (!checkhowtouse) {
      showDialog(
        barrierDismissible: false,
        context: context,
        builder: (context) {
          return Dialog_HowtoUse();
        },
      );
    }
    // prefs.setBool("checkhowtouse", false);
  }

  @override
  void initState() {
    super.initState();
    initializeCamera(selectedCamera); //Initially selectedCamera = 0
    getDeviceId();
    _checkHowtoUse();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      checkAndShowBottomSheet();
    });
  }

  void checkAndShowBottomSheet() async {
    final provider = Provider.of<ProcessCountProvider>(context, listen: false);
    await provider.checkProcessCount();

    if (provider.isLimitReached && mounted) {
      showModalBottomSheet(
        context: context,
        builder: (context) => BottomSheetGemini(),
        isDismissible: false,
        enableDrag: true,
      );
    }
  }

  Future<bool> _checkRealInternetConnectivity() async {
    try {
      final result = await InternetAddress.lookup('example.com');
      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } on SocketException catch (_) {
      return false;
    }
  }

  Future<bool> _checkInternetConnection() async {
    var connectivityResult = await _connectivity.checkConnectivity();
    if (connectivityResult == ConnectivityResult.none) {
      _updateNoInternetState(true);
      return true; // ส่ง true เมื่อไม่มีการเชื่อมต่ออินเทอร์เน็ต
    } else {
      bool hasRealConnectivity = await _checkRealInternetConnectivity();
      _updateNoInternetState(!hasRealConnectivity);
      return !hasRealConnectivity; // ส่ง true เมื่อไม่มีการเชื่อมต่ออินเทอร์เน็ตจริง ๆ
    }
  }

  void _updateNoInternetState(bool noInternet) {
    setState(() {
      _noInternet = noInternet;
    });

    if (_noInternet) {
      _showNoInternetModal();
    } else {
      _dismissNoInternetModal();
    }
  }

  void _showNoInternetModal() {
    if (!_isBottomSheetShown) {
      _isBottomSheetShown = true;
      showMaterialModalBottomSheet(
        context: context,
        isDismissible: false, // ไม่ให้ปิด Modal โดยการแตะด้านนอก
        enableDrag: true, // อนุญาตให้ลากปิด Modal
        builder: (BuildContext context) {
          return WillPopScope(
            onWillPop: () async {
              // เมื่อผู้ใช้กดปุ่มย้อนกลับ
              capturedImages.clear(); // เคลียร์ capturedImages ก่อนปิด Modal
              _isBottomSheetShown = false; // รีเซ็ตสถานะเมื่อปิด Modal
              Navigator.of(context).pop(); // ปิด Modal
              setState(() {});
              return false; // บอกว่าจะไม่ให้ปิด Modal โดยอัตโนมัติ
            },
            child: SizedBox(
              height: 250,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.portable_wifi_off,
                    size: 80,
                    color: Colors.red.shade300,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    "ตอนนี้คุณไม่ได้เชื่อมต่ออินเทอร์เน็ต",
                    style: TextStyle(
                      fontSize: 18,
                      color: Colors.red.shade400,
                    ),
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: () {
                      _checkInternetConnection();
                      capturedImages.clear();
                    },
                    style: ButtonStyle(
                      backgroundColor:
                          WidgetStateProperty.all(Colors.red.shade300),
                    ),
                    child: const Text(
                      "ลองใหม่",
                      style: TextStyle(color: WhiteColor, fontSize: 15),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ).whenComplete(() {
        _isBottomSheetShown = false; // รีเซ็ตสถานะเมื่อปิด Modal
      });
    }
  }

  void _dismissNoInternetModal() {
    if (_isBottomSheetShown) {
      Navigator.of(context).pop();
      _isBottomSheetShown = false;
    }
  }

  int selectedCamera = 0;
  List<CapturedImage> capturedImages = [];
  // List<File> capturedImages = [];

  initializeCamera(int cameraIndex) async {
    _controller = CameraController(
        // Get a specific camera from the list of available camera.
        widget.camera[cameraIndex],
        // Define the resolution to use.
        ResolutionPreset.max, // new resolution
        enableAudio: false);
    _initializeControllerFuture = _controller.initialize();
  }

  @override
  void dispose() {
    // _lightMeterTimer?.cancel();
    // _controller.stopImageStream();
    _controller.dispose();
    super.dispose();
  }

  File? image;
  String imageUrl = '';

  Uint8List preProcessingImage(File capturedImages) {
    // อ่านภาพและ resize ให้เป็น 64x64
    img.Image? image = img.decodeImage(capturedImages.readAsBytesSync());
    img.Image? resizedImage = img.copyResize(image!, width: 64, height: 64);

    // แปลงเป็น Uint8List (พิกเซลในรูปแบบตัวเลข)
    Uint8List bytes = resizedImage.getBytes();

    // สร้าง Float32List สำหรับการ normalize ค่าพิกเซล
    Float32List normalizedBytes = Float32List(bytes.length);
    for (int i = 0; i < bytes.length; i++) {
      normalizedBytes[i] = bytes[i] / 255.0;
    }

    return normalizedBytes.buffer.asUint8List();
  }

  Future<void> runInference(File images, int index) async {
    try {
      final output = await context.read<ModelState>().runModelInference(images);
      print('Raw output: $output');

      // ตรวจสอบค่าผลลัพธ์และแปลงเป็นสถานะ
      int numberresult = output > 0.5 ? 1 : 2;

      // อัปเดตสถานะ UI
      context.read<ImageState>().updateStatusMangoColor(index, numberresult);
      checkCapturedImages();

      if (context.read<ImageState>().isAllImagesComplete) {
        debugPrint("ครบ 4 รูปภาพเรียบร้อยแล้ว");
        await uploadImageAndUpdateState();
      }
    } catch (e) {
      debugPrint('Error processing Image: $e');
    }
  }

  Future<void> _openGallery(BuildContext context) async {
    final imageState = context.read<ImageState>();

    await imageState.pickImagesFromGallery(
      onError: (String error) {
        debugPrint('เกิดข้อผิดพลาด: $error');
        // แสดง dialog หรือ snackbar แจ้งเตือนผู้ใช้
      },
      onNoInternet: () {
        debugPrint("ไม่มีการเชื่อมต่ออินเทอร์เน็ต");
        // แสดง dialog หรือ snackbar แจ้งเตือนผู้ใช้
      },
      analyzeImage: (File imageFile, int status) async {
        // เรียกใช้ฟังก์ชัน analyzeImage ของคุณที่นี่
        await analyzeImage(imageFile, status);
      },
      checkInternetConnection: () async {
        // ใส่โค้ดตรวจสอบอินเทอร์เน็ตของคุณที่นี่
        return await _checkInternetConnection();
      },
    );
  }

  CapturedImage? findCapturedImageByStatusImage(int statusImage) {
    try {
      final images = context.read<ImageState>().getAllImages;
      return images.firstWhere(
        (image) => image.statusimage == statusImage,
      );
    } catch (e) {
      return null; // คืนค่า null ถ้าไม่พบภาพที่ตรงกับ statusImage
    }
  }

  Future _checkDetectCoin(File imagename, int index) async {
    try {
      final bytes = await imagename.readAsBytes();
      final image = img.decodeImage(bytes);

      if (image == null) {
        print("Error: Cannot decode image for coin detection");
        return;
      }

      // Resize image ถ้าต้องการ
      final resizedImage =
          img.copyResize(image, width: 1000); // ปรับขนาดตามต้องการ
      final compressedBytes = img.encodeJpg(resizedImage, quality: 80);

      // 2. แปลงรูปภาพเป็น base64
      final base64Image = base64Encode(compressedBytes);

      var firebasefunctions =
          FirebaseFunctions.instanceFor(region: 'asia-southeast1');

      final previewResult = {"imagename": base64Image, 'format': 'jpg'};
      print("Calling detectcoin10and5 function...");

      final result = await firebasefunctions
          .httpsCallable("detectcoin10and5")
          .call(previewResult)
          .timeout(Duration(seconds: 30)); // Add timeout

      print("Coin detection result: ${result.data}");

      if (result.data != null) {
        final Map<String, dynamic> data =
            Map<String, dynamic>.from(result.data);
        final message = data['message'];

        if (message == "เป็นเหรียญ 5 บาท") {
          print("Coin detected: 5 baht coin found");
          return;
        } else {
          print("Coin detection: Not a 5 baht coin - $message");
          context.read<ImageState>().updateStatusMango(index, 2);
          return;
        }
      } else {
        print("Coin detection: No valid response data");
        // Don't update status if function returns null
        return;
      }
    } on TimeoutException catch (error) {
      debugPrint('Coin detection timeout: $error');
      // Skip coin detection on timeout, don't mark as invalid
      return;
    } on FirebaseFunctionsException catch (error) {
      debugPrint(
          'Functions error code: ${error.code}, details: ${error.details}, message: ${error.message}');

      // Handle specific error codes
      if (error.code == 'not-found') {
        debugPrint('Firebase function not found - skipping coin detection');
        // Skip coin detection if function doesn't exist
        return;
      } else if (error.code == 'unauthenticated') {
        debugPrint('Authentication error - user not authenticated');
        Navigator.of(context).pop();
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext context) {
            return Dialog_Error(
                name: "เกิดข้อผิดพลาดการยืนยันตัวตน",
                content: "กรุณาเข้าสู่ระบบใหม่อีกครั้ง");
          },
        );
        return;
      } else {
        // For other errors, show generic error but don't fail the whole process
        debugPrint('Coin detection failed, continuing without coin validation');
        return;
      }
    } catch (error) {
      debugPrint('Unexpected error in coin detection: $error');
      // Skip coin detection on unexpected errors
      return;
    }
  }

  Future uploadImageAndUpdateState() async {
    if (context.read<ImageState>().isImagesFull) {
      showDialog(
        barrierDismissible: false,
        context: context,
        builder: (context) => PopScope(
          canPop: false,
          child: Center(
            child: AlertDialog(
              backgroundColor: GPrimaryColor.withOpacity(0.6),
              contentPadding:
                  const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
              title: Column(
                children: [
                  const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'กำลังไปยังขั้นตอนต่อไป',
                      style: TextStyle(color: WhiteColor, fontSize: 20),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(
                    height: 15,
                  ),
                  LoadingAnimationWidget.discreteCircle(
                    color: WhiteColor,
                    secondRingColor: GPrimaryColor,
                    thirdRingColor: YPrimaryColor,
                    size: 70,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      try {
        print("พบสีเหลือง");

        String uniquename = DateTime.now().millisecondsSinceEpoch.toString();

        // ชื่อของรูปภาพที่ต้องการ
        List<String> imageNames = [
          'Front_$uniquename',
          'Back_$uniquename',
          'Bottom_$uniquename',
          'Top_$uniquename',
        ];

        List<String> imageuri = [];
        List<String> downloaduri = [];
        List<String> listImagepath = [];

        bool allImagesUploaded = true;
        String errorMessage = "";

        for (int i = 1; i <= 4; i++) {
          final capturedImage = findCapturedImageByStatusImage(i);

          if (capturedImage == null) {
            print("ไม่พบภาพสำหรับ statusimage $i");
            allImagesUploaded = false;
            errorMessage = "ไม่พบภาพที่จำเป็นสำหรับการอัปโหลด";
            break;
          }

          try {
            final result = await uploadImageToCloudStorage(
                capturedImage.image, imageNames[i - 1]);

            if (result.containsKey('downloadURL') &&
                result.containsKey('imageName') &&
                result['downloadURL']!.isNotEmpty &&
                result['imageName']!.isNotEmpty) {
              final imagePath = await saveImageToDevice(
                  capturedImage.image, imageNames[i - 1]);

              stdout.writeln('Saved image path: $imagePath');
              listImagepath.add(imagePath.toString());
              downloaduri.add(result['downloadURL']!);
              imageuri.add(result['imageName']!);
            } else {
              print(
                  "Upload failed or invalid result for statusimage $i: $result");
              allImagesUploaded = false;
              errorMessage = "การอัปโหลดภาพล้มเหลวสำหรับภาพที่ $i";
              break;
            }
          } catch (e) {
            print("Error uploading image $i: $e");
            allImagesUploaded = false;
            errorMessage =
                "เกิดข้อผิดพลาดในการอัปโหลดภาพที่ $i: ${e.toString()}";
            break;
          }
        }

        if (allImagesUploaded &&
            downloaduri.length == 4 &&
            imageuri.length == 4) {
          String downloadurl = downloaduri.join(',');
          String concatenatedString = imageuri.join(',');

          final imageState = context.read<ImageState>();
          final capturedImagesFiles = imageState.getSortedImageFiles;

          final previewResult = {
            'downloadurl': downloadurl,
            "imagename": concatenatedString,
            "ip": _mobileDeviceIdentifier,
            "result": "Yellow"
          };

          debugPrint("Upload successful: $previewResult");
          debugPrint("เสร็จสิ้น");

          Navigator.of(context).pop();
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => WeightNumber(
                camera: widget.camera,
                capturedImage: capturedImagesFiles,
                ListImagePath: listImagepath,
                httpscall: previewResult,
              ),
            ),
          );
          context.read<ImageState>().imageclean();
        } else {
          Navigator.of(context).pop();
          await showDialog(
            context: context,
            barrierDismissible: false,
            builder: (BuildContext context) {
              return Dialog_Error(
                  name: "เกิดข้อผิดพลาดในการอัปโหลดภาพ",
                  content: errorMessage.isNotEmpty
                      ? errorMessage
                      : "ไม่สามารถอัปโหลดภาพได้ กรุณาลองใหม่อีกครั้ง");
            },
          );
          context.read<ImageState>().imageclean();
        }
      } catch (e) {
        Navigator.of(context).pop();
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext context) {
            return Dialog_Error(
                name: "เกิดข้อผิดพลาดที่ไม่คาดคิด",
                content: "เกิดข้อผิดพลาด: ${e.toString()}");
          },
        );
        context.read<ImageState>().imageclean();
      }
    } else {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) {
          return Dialog_Error(
              name: "เกิดข้อผิดพลาด",
              content: "ภาพไม่ครบ 4 ภาพ กรุณาถ่ายภาพให้ครบ");
        },
      );
    }
  }

  Future<String> saveImageToDevice(File imageFile, String imageName) async {
    final directory = await getApplicationDocumentsDirectory();
    final path = directory.path;
    final fileName = '$path/$imageName';
    final savedImage = await imageFile.copy(fileName);
    return savedImage.path;
  }

  Future<Map<String, String>> uploadImageToCloudStorage(
      File imageFile, String imageName) async {
    try {
      debugPrint('=== Starting upload for $imageName ===');

      // ตรวจสอบการเชื่อมต่ออินเทอร์เน็ต
      try {
        final result = await InternetAddress.lookup('google.com')
            .timeout(Duration(seconds: 10));
        if (result.isNotEmpty && result[0].rawAddress.isNotEmpty) {
          debugPrint('Internet connection: OK');
        }
      } catch (e) {
        debugPrint('Internet connection check failed: $e');
        throw Exception('กรุณาตรวจสอบการเชื่อมต่ออินเทอร์เน็ต');
      }

      // ตรวจสอบว่าไฟล์มีอยู่จริง
      if (!await imageFile.exists()) {
        debugPrint('File does not exist: ${imageFile.path}');
        throw Exception('ไฟล์ภาพไม่พบ: ${imageFile.path}');
      }

      // ตรวจสอบขนาดไฟล์
      final fileSize = await imageFile.length();
      if (fileSize == 0) {
        debugPrint('File is empty: ${imageFile.path}');
        throw Exception('ไฟล์ภาพเสียหาย หรือไฟล์ว่าง');
      }

      debugPrint('File validation OK: $imageName, Size: ${fileSize} bytes');

      final storageRef =
          FirebaseStorage.instance.ref().child('image_analysis/$imageName');

      // เปลี่ยนประเภทเป็นรูป
      final metadata = SettableMetadata(contentType: 'image/jpg');

      debugPrint('Starting Firebase Storage upload...');
      final uploadTask = storageRef.putFile(imageFile, metadata);

      // เพิ่ม progress tracking
      uploadTask.snapshotEvents.listen((TaskSnapshot snapshot) {
        double progress =
            (snapshot.bytesTransferred / snapshot.totalBytes) * 100;
        debugPrint(
            'Upload progress for $imageName: ${progress.toStringAsFixed(1)}%');
      }, onError: (e) {
        debugPrint('Upload stream error for $imageName: $e');
      });

      // รอการอัปโหลดเสร็จสิ้น
      final snapshot = await uploadTask.whenComplete(() => null);

      // ตรวจสอบสถานะการอัปโหลด
      if (snapshot.state != TaskState.success) {
        debugPrint('Upload failed with state: ${snapshot.state}');
        throw Exception('การอัปโหลดไม่สำเร็จ: ${snapshot.state}');
      }

      debugPrint('Upload completed, getting download URL...');
      String downloadURL = await snapshot.ref.getDownloadURL();

      // ตรวจสอบว่า downloadURL ไม่เป็นค่าว่าง
      if (downloadURL.isEmpty) {
        debugPrint('Download URL is empty');
        throw Exception('ไม่สามารถได้รับ Download URL');
      }

      final result = {'downloadURL': downloadURL, 'imageName': imageName};
      debugPrint('Upload successful: $imageName -> $downloadURL');
      return result;
    } on FirebaseException catch (e) {
      debugPrint('Firebase error for $imageName: ${e.code} - ${e.message}');
      String errorMessage;
      switch (e.code) {
        case 'storage/unauthorized':
          errorMessage = 'ไม่มีสิทธิ์ในการอัปโหลดภาพ';
          break;
        case 'storage/canceled':
          errorMessage = 'การอัปโหลดถูกยกเลิก';
          break;
        case 'storage/unknown':
          errorMessage =
              'เกิดข้อผิดพลาดที่ไม่ทราบสาเหตุ กรุณาตรวจสอบการเชื่อมต่ออินเทอร์เน็ต';
          break;
        case 'storage/retry-limit-exceeded':
          errorMessage = 'การเชื่อมต่อไม่เสถียร กรุณาลองใหม่อีกครั้ง';
          break;
        case 'storage/quota-exceeded':
          errorMessage = 'เนื้อที่จัดเก็บเต็ม';
          break;
        default:
          errorMessage = 'เกิดข้อผิดพลาดจาก Firebase: ${e.message ?? e.code}';
      }
      throw Exception(errorMessage);
    } on SocketException catch (e) {
      debugPrint('Network error for $imageName: $e');
      throw Exception('กรุณาตรวจสอบการเชื่อมต่ออินเทอร์เน็ต');
    } on TimeoutException catch (e) {
      debugPrint('Timeout error for $imageName: $e');
      throw Exception('การเชื่อมต่อล่าช้า กรุณาลองใหม่อีกครั้ง');
    } catch (e) {
      debugPrint('Unexpected error for $imageName: $e');
      throw Exception(
          'เกิดข้อผิดพลาดในการอัปโหลดภาพ $imageName: ${e.toString()}');
    }
  }

  late int flashstatus = 0;

  String mapIndexToText(int index) {
    switch (index) {
      case 1:
        return "หน้า";
      case 2:
        return "หลัง";
      case 3:
        return "ล่าง";
      case 4:
        return "บน";
      default:
        return "ไม่ทราบตำแหน่ง"; // สำหรับค่าที่ไม่อยู่ในช่วง 1-4
    }
  }

  String _getProblemReason(ProblematicImage image) {
    if (image.isStatusMangoProblem && image.isStatusMangoColorProblem) {
      return "ไม่มีมะม่วงในภาพและสีไม่ถูกต้อง";
    } else if (image.isStatusMangoProblem) {
      return "ไม่มีมะม่วงในภาพ";
    } else if (image.isStatusMangoColorProblem) {
      return "สีของมะม่วงไม่ถูกต้อง";
    } else {
      return "เกิดข้อผิดพลาด";
    }
  }

  bool _hasSavedToFirebase = false;
  bool _hasShownDialog =
      false; // ตัวแปร flag เพื่อตรวจสอบว่า Dialog ได้แสดงหรือยัง

  void checkCapturedImages() {
    // ตรวจสอบว่ามี capturedImages ครบ 4 ภาพ
    if (context.read<ImageState>().isImagesFull) {
      // ตรวจสอบว่า status ของภาพทั้งหมดถูกประมวลผลแล้ว
      final capturedImage = context.read<ImageState>().getAllImages;
      bool allImagesProcessed = capturedImages.every(
          (image) => image.statusMango != 0 || image.statusMangoColor != 0);

      // หากทุกภาพได้รับการประมวลผลแล้ว
      debugPrint(allImagesProcessed.toString());
      if (allImagesProcessed && !_hasShownDialog) {
        // ตรวจสอบว่าภาพประมวลผลเสร็จและยังไม่เคยแสดง Dialog
        // ภาพที่มีปัญหา (statusMango == 2 หรือ statusMangoColor == 2)
        List<ProblematicImage> problematicImages = capturedImage
            .where((image) =>
                image.statusMango == 2 || image.statusMangoColor == 2)
            .map((image) => ProblematicImage(
                  statusimage: image.statusimage,
                  isStatusMangoProblem: image.statusMango == 2,
                  isStatusMangoColorProblem: image.statusMangoColor == 2,
                ))
            .toList()
          ..sort((a, b) => a.statusimage.compareTo(b.statusimage));

        // ตรวจสอบว่ามีภาพที่ไม่ผ่านการวิเคราะห์หรือไม่
        if (problematicImages.isNotEmpty) {
          _hasShownDialog = true; // แสดง Dialog แค่ครั้งเดียว
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (BuildContext context) {
              return AlertDialog(
                backgroundColor: WhiteColor,
                surfaceTintColor: WhiteColor,
                title: Text(
                  'พบรูปภาพที่ไม่ถูกต้อง',
                  style: TextStyle(
                      color: Colors.red.shade400,
                      fontSize: 18,
                      fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FittedBox(
                      child: Text(
                        'ภาพที่ไม่ถูกต้องมีดังนี้ :',
                        style: TextStyle(
                          color: Colors.black,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    SizedBox(height: 10),
                    for (var problematicImage in problematicImages)
                      ListTile(
                        leading: Icon(
                          Icons.image_rounded,
                          size: 25,
                          color: Colors.red.shade400,
                        ),
                        title: Wrap(
                          alignment: WrapAlignment.start,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              "ภาพด้าน ",
                              style: TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.bold),
                            ),
                            Text(
                              "${mapIndexToText(problematicImage.statusimage)} ",
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                                color: GPrimaryColor,
                              ),
                            ),
                            Text(
                              "เนื่องจาก ",
                              style: TextStyle(fontSize: 15),
                            ),
                            Text(
                              _getProblemReason(problematicImage),
                              style: TextStyle(
                                fontSize: 15,
                                color: Colors.black,
                              ),
                            ),
                          ],
                        ),
                      ),
                    SizedBox(height: 10),
                    FittedBox(
                      child: Text(
                        'กรุณาถ่ายภาพด้านดังกล่าวใหม่อีกครั้ง',
                        style: TextStyle(
                            color: Colors.red.shade300,
                            fontSize: 18,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                actions: <Widget>[
                  SizedBox(
                    child: ElevatedButton(
                        style: ButtonStyle(
                            backgroundColor:
                                WidgetStatePropertyAll(GPrimaryColor),
                            elevation: WidgetStatePropertyAll(1)),
                        onPressed: () async {
                          _hasShownDialog =
                              false; // รีเซ็ต flag เมื่อปิด Dialog
                          Navigator.of(context).pop();
                        },
                        child: Text('เข้าใจแล้ว',
                            style: TextStyle(
                              color: WhiteColor,
                              fontSize: 16,
                            ))),
                  ),
                ],
              );
            },
          );
        } else if (!_hasSavedToFirebase) {
          _hasSavedToFirebase = true;
          saveGeminiCountToFirebase();
        }
      }
    }
  }

  Future<void> analyzeImage(File image, int index) async {
    try {
      setState(() {
        geminiProcessCount++;
      });

      debugPrint(
          "Starting Gemini analysis for image $index (total calls: $geminiProcessCount)");

      final result = await _callGeminiWithRetry(image, index);

      final geminiText = (result?.content?.parts?.last.text ?? '').trim();
      debugPrint("Gemini response for image $index: $geminiText");

      setState(() {
        if (geminiText == "mango" || geminiText == "mango.") {
          context.read<ImageState>().updateStatusMango(index, 1);
          runInference(image, index);
        } else {
          context.read<ImageState>().updateStatusMango(index, 2);
        }
        checkCapturedImages();
      });

      // Only call coin detection if mango is detected
      if (geminiText == "mango" || geminiText == "mango.") {
        await _checkDetectCoin(image, index);
      }
    } on TimeoutException catch (error) {
      setState(() {
        geminiProcessCount--;
      });
      debugPrint("Gemini timeout error: $error");
      await _showGeminiErrorDialog("การวิเคราะห์ล้มเหลว",
          "การวิเคราะห์ภาพใช้เวลานานเกินไป กรุณาลองใหม่อีกครั้ง");
    } catch (error) {
      setState(() {
        geminiProcessCount--;
      });
      debugPrint("Gemini analysis error: $error");

      String errorMessage =
          "ไม่สามารถวิเคราะห์ภาพได้ กรุณาตรวจสอบการเชื่อมต่ออินเทอร์เน็ตและลองใหม่อีกครั้ง";

      if (error.toString().contains('429')) {
        errorMessage =
            "มีการใช้งานจำนวนมากเกินไป กรุณารอสักครู่แล้วลองใหม่อีกครั้ง";
      }

      await _showGeminiErrorDialog(
          "เกิดข้อผิดพลาดในการวิเคราะห์", errorMessage);
    }
  }

  Future<dynamic> _callGeminiWithRetry(File image, int index,
      {int maxRetries = 3}) async {
    final rateLimiter = GeminiRateLimiter();

    return await rateLimiter.executeRequest(() async {
      for (int attempt = 1; attempt <= maxRetries; attempt++) {
        try {
          debugPrint(
              "Gemini API call attempt $attempt/$maxRetries for image $index");

          // Add delay between retries, with exponential backoff
          if (attempt > 1) {
            int delaySeconds = (attempt - 1) * 3; // 3s, 6s, 9s...
            debugPrint("Waiting ${delaySeconds}s before retry...");
            await Future.delayed(Duration(seconds: delaySeconds));
          }

          final gemini = Gemini.instance;
          final result = await gemini.textAndImage(
            text: """
              ฉันจะส่งรูปภาพให้คุณ ให้คุณลองเช็คดูว่าในรูปนี้มีมะม่วงมั้ย ถ้าเป็นมะม่วงให้ตอบว่า "mango"
              ถ้าไม่เป็นมะม่วงหรือไม่มีมะม่วง ให้ตอบว่า "ไม่ใช่มะม่วง" โดยฉันขออธิบายเพิ่มเติมว่า มะม่วงที่ฉันจะส่งรูปภาพให้คุณ มีทั้งมะม่วงที่ถ่ายจากด้านหน้า ด้านหลัง ด้านล่าง และด้านบนของมะม่วง เพราะฉะนั้นฉันคิดว่าคุณน่าจะทราบอยู่แล้วว่ามะม่วงมีลักษณะอย่างไร
              และเพิ่มเติมช่วยบอกสาเหตุฉันหน่อยว่า ทำไมไม่ใช่มะม่วง
            """,
            images: [await image.readAsBytes()],
          ).timeout(Duration(seconds: 60)); // Increased timeout

          debugPrint("Gemini API call successful for image $index");
          return result;
        } catch (error) {
          debugPrint(
              "Gemini API call attempt $attempt failed for image $index: $error");

          bool shouldRetry = false;
          if (error.toString().contains('429')) {
            shouldRetry = true;
            debugPrint("Rate limit error detected, will retry...");
          } else if (error is TimeoutException) {
            shouldRetry = attempt < maxRetries;
            debugPrint("Timeout error, will retry: $shouldRetry");
          } else if (error.toString().toLowerCase().contains('network') ||
              error.toString().toLowerCase().contains('connection')) {
            shouldRetry = attempt < maxRetries;
            debugPrint("Network error, will retry: $shouldRetry");
          }

          if (!shouldRetry || attempt == maxRetries) {
            throw error;
          }
        }
      }

      throw Exception("All retry attempts failed");
    });
  }

  Future<void> _showGeminiErrorDialog(String title, String content) async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return Dialog_Error(name: title, content: content);
      },
    );
  }

  int geminiProcessCount = 0;
  Future<void> saveGeminiCountToFirebase() async {
    try {
      final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
      await FirebaseFirestore.instance
          .collection('GeminiProcesscount')
          .doc(today)
          .set(
              {
            'process_count': FieldValue.increment(
                geminiProcessCount), // เพิ่มค่าครั้งการประมวลผล
            'last_updated': FieldValue.serverTimestamp(),
          },
              SetOptions(
                  merge: true)); // ใช้ merge เพื่ออัปเดตข้อมูลเดิมหากมีอยู่แล้ว
      debugPrint('บันทึกจำนวนครั้งลง Firebase สำเร็จ');
    } catch (e) {
      debugPrint('เกิดข้อผิดพลาดในการบันทึกลง Firebase: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Consumer<ModelState>(builder: (context, state, child) {
      if (state.isLoading) {
        return const Center(child: CircularProgressIndicator());
      } else {
        return Scaffold(
          appBar: const AppbarMains(name: 'วิเคราะห์คุณภาพ'),
          // You must wait until the controller is initialized before displaying the
          // camera preview. Use a FutureBuilder to display a loading spinner until the
          // controller has finished initializing.
          body: Column(
            children: [
              Expanded(
                flex: 8,
                child: Stack(
                  children: [
                    SizedBox(
                      child: FutureBuilder<void>(
                        future: _initializeControllerFuture,
                        builder: (context, snapshot) {
                          if (!_controller.value.isInitialized) {
                            return const Center(
                                child:
                                    CircularProgressIndicator()); // หรือ loading indicator
                          }
                          return SizedBox(
                              width: size.width,
                              height: size.height * 0.8,
                              child: FittedBox(
                                fit: BoxFit.cover,
                                child: SizedBox(
                                    width:
                                        100, // the actual width is not important here
                                    child: CameraPreview(_controller)),
                              ));
                          // if (snapshot.connectionState == ConnectionState.done) {
                          //   // If the Future is complete, display the preview.
                          // } else {
                          //   // Otherwise, display a loading indicator.
                          // }
                        },
                      ),
                    ),
                    Positioned(
                      top: 0,
                      right: 0,
                      left: 0,
                      child: Container(
                        color: Colors.transparent,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            IconButton(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 10),
                              onPressed: () {
                                if (widget.camera.length > 1) {
                                  setState(() {
                                    if (flashstatus == 0) {
                                      _controller.setFlashMode(FlashMode.torch);
                                      flashstatus = 1;
                                    } else {
                                      _controller.setFlashMode(FlashMode.off);
                                      flashstatus = 0;
                                    }
                                  });
                                } else {
                                  ScaffoldMessenger.of(context)
                                      .showSnackBar(const SnackBar(
                                    content: Text('No secondary camera found'),
                                    duration: Duration(seconds: 2),
                                  ));
                                }
                              },
                              icon: const Icon(
                                Icons.flash_on_rounded,
                                color: Colors.white,
                                size: 40,
                              ),
                            ),
                            IconButton(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 10),
                              onPressed: () {
                                if (widget.camera.length > 1) {
                                  setState(() {
                                    selectedCamera =
                                        selectedCamera == 0 ? 1 : 0;
                                    initializeCamera(selectedCamera);
                                  });
                                } else {
                                  ScaffoldMessenger.of(context)
                                      .showSnackBar(const SnackBar(
                                    content: Text('No secondary camera found'),
                                    duration: Duration(seconds: 2),
                                  ));
                                }
                              },
                              icon: const Icon(
                                Icons.flip_camera_ios_rounded,
                                color: Colors.white,
                                size: 40,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    context.watch<ImageState>().selectedStatus == 3 ||
                            context.watch<ImageState>().selectedStatus == 4
                        ? Positioned(
                            bottom: 180,
                            left: 50,
                            child: Container(
                              width: 300,
                              height: 300,
                              decoration: BoxDecoration(
                                color: Colors.transparent,
                                border: Border.all(color: WhiteColor, width: 3),
                              ),
                            ),
                          )
                        : Positioned(
                            bottom: 125,
                            left: 100,
                            child: Container(
                              width: 200,
                              height: 350,
                              decoration: BoxDecoration(
                                color: Colors.transparent,
                                border: Border.all(color: WhiteColor, width: 3),
                              ),
                            ),
                          ),
                    Positioned(
                      bottom: 10,
                      right: 0,
                      left: 0,
                      child: Container(
                        color: Colors.transparent,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: List.generate(4, (index) {
                            final labels = [
                              'ด้านหน้า',
                              'ด้านหลัง',
                              'ด้านล่าง',
                              'ด้านบน'
                            ];
                            final image =
                                context.select<ImageState, CapturedImage?>(
                                    (state) => state.capturedImages
                                        .where((img) =>
                                            img.statusimage == index + 1)
                                        .firstOrNull);

                            return ImageGridItem(
                              index: index,
                              label: labels[index],
                              image: image,
                            );
                          }),
                        ),
                      ),
                    )
                  ],
                ),
              ),
              Expanded(
                flex: 3,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 20),
                    child: Column(
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(bottom: 10),
                          child: Text(
                            "พยายามให้ลูกมะม่วงของคุณ\nอยู่ภายในระยะกรอบสีขาว",
                            maxLines: 3,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: GPrimaryColor),
                          ),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      onPressed: () => _openGallery(context),
                                      icon: const Icon(
                                        Icons.image_rounded,
                                        color: GPrimaryColor,
                                        size: 40,
                                      ),
                                    ),
                                    const Text(
                                      "รูปภาพ",
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          color: GPrimaryColor, fontSize: 12),
                                    )
                                  ],
                                ),
                              ),
                            ),
                            Expanded(
                              child: Center(
                                child: Consumer<ImageState>(
                                  builder: (context, imageState, child) {
                                    return GestureDetector(
                                      onTap: imageState.isImagesFull
                                          ? null
                                          : () async {
                                              await _initializeControllerFuture;

                                              // ตั้งค่าแฟลชตาม flashstatus
                                              if (flashstatus == 0) {
                                                _controller.setFlashMode(
                                                    FlashMode.off);
                                              }

                                              // ถ่ายรูป
                                              var xFile = await _controller
                                                  .takePicture();

                                              // ใช้ selectedStatus ปัจจุบันจาก Provider
                                              int statusN =
                                                  imageState.selectedStatus;

                                              // เพิ่มรูปภาพผ่าน Provider
                                              context
                                                  .read<ImageState>()
                                                  .addCapturedImage(
                                                      File(xFile.path),
                                                      statusN);

                                              debugPrint(
                                                  "ตัวเลขสถานะ $statusN");

                                              // เช็คการเชื่อมต่ออินเทอร์เน็ตและวิเคราะห์ภาพ
                                              bool noInternet =
                                                  await _checkInternetConnection();
                                              if (!noInternet) {
                                                await analyzeImage(
                                                    File(xFile.path), statusN);
                                              }
                                            },
                                      child: Container(
                                        height: 60,
                                        width: 60,
                                        decoration: const BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: GPrimaryColor,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                            Expanded(
                              child: Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      onPressed: () {
                                        showDialog(
                                          barrierDismissible: false,
                                          context: context,
                                          builder: (context) {
                                            return Dialog_HowtoUse();
                                          },
                                        );
                                      },
                                      icon: const Icon(
                                        Icons.help_outline_rounded,
                                        color: GPrimaryColor,
                                        size: 40,
                                      ),
                                    ),
                                    const Text(
                                      "คู่มือการถ่ายภาพ",
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          color: GPrimaryColor, fontSize: 12),
                                    )
                                  ],
                                ),
                              ),
                            ),
                          ],
                        )
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      }
    });
  }
}
