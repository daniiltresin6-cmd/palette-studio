package com.palette.studio

import android.content.ContentValues
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.provider.MediaStore
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStream

class ImageSaverMethodChannel : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var applicationContext: android.content.Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "image_saver")
        channel.setMethodCallHandler(this)
        applicationContext = binding.applicationContext
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "saveImage" && applicationContext != null) {
            val bytes = call.argument<ByteArray>("bytes") ?: return result.error("NO_BYTES", "No image data", null)
            val name = call.argument<String>("name") ?: "palette_${System.currentTimeMillis()}"
            
            try {
                val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                val contentValues = ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, "$name.png")
                    put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/PaletteStudio")
                        put(MediaStore.Images.Media.IS_PENDING, 1)
                    }
                }

                val uri = applicationContext!!.contentResolver.insert(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI, 
                    contentValues
                )

                if (uri != null) {
                    applicationContext!!.contentResolver.openOutputStream(uri)?.use { outputStream ->
                        bitmap.compress(Bitmap.CompressFormat.PNG, 100, outputStream)
                    }
                    
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        contentValues.clear()
                        contentValues.put(MediaStore.Images.Media.IS_PENDING, 0)
                        applicationContext!!.contentResolver.update(uri, contentValues, null, null)
                    }
                    
                    result.success(true)
                } else {
                    result.error("INSERT_FAILED", "Could not insert into MediaStore", null)
                }
            } catch (e: Exception) {
                result.error("SAVE_ERROR", e.message, null)
            }
        } else {
            result.notImplemented()
        }
    }
}