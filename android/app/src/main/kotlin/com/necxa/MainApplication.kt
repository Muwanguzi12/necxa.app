package com.necxa

import android.app.Application
import android.content.Context
import androidx.multidex.MultiDex
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions

class MainApplication : Application() {
    
    companion object {
        lateinit var instance: MainApplication
            private set
    }
    
    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
        MultiDex.install(this)
    }
    
    override fun onCreate() {
        super.onCreate()
        instance = this
        
        // Initialize ML Kit Face Detector with optimal settings
        initializeFaceDetector()
    }
    
    private fun initializeFaceDetector() {
        Thread {
            try {
                val options = FaceDetectorOptions.Builder()
                    .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
                    .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_ALL)
                    .setClassificationMode(FaceDetectorOptions.CLASSIFICATION_MODE_ALL)
                    .setContourMode(FaceDetectorOptions.CONTOUR_MODE_ALL)
                    .setMinFaceSize(0.15f)
                    .enableTracking()
                    .build()
                FaceDetection.getClient(options)
            } catch (t: Throwable) {
                // Fail-safe: do not block app startup if ML Kit native libraries fail to load
            }
        }.start()
    }
}
