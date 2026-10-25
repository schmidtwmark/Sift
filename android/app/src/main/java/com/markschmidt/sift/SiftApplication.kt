package com.markschmidt.sift

import android.app.Application
import android.content.Context
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.TimeUnit

class SiftApplication : Application() {
    lateinit var model: AppModel
        private set

    override fun onCreate() {
        super.onCreate()
        model = AppModel(this)
        model.notifier.createChannels()
        // Push only while Sift is in front; in the background, Android's
        // scheduler wakes it every so often to sort new mail and alert.
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) = model.onForeground()
            override fun onStop(owner: LifecycleOwner) = model.onBackground()
        })
        RefreshWorker.schedule(this)
    }
}

val Context.model: AppModel get() = (applicationContext as SiftApplication).model

/**
 * Background refresh, like iOS background app refresh: sorts new mail and
 * posts alerts for senders who have them on. Android runs it about every 15
 * minutes at best, so it can be late.
 */
class RefreshWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result = withContext(Dispatchers.Main) {
        val model = applicationContext.model
        if (model.phase == AppModel.Phase.Launching) model.launch()
        // Give a cold start time to connect and do its first sync.
        withTimeoutOrNull(60_000) {
            while (model.phase != AppModel.Phase.Ready) {
                if (model.phase == AppModel.Phase.SignedOut || model.phase is AppModel.Phase.Failed) return@withTimeoutOrNull
                delay(500)
            }
            if (!model.isDemo) model.refresh(AppModel.RefreshTrigger.AUTOMATIC)
        }
        Result.success()
    }

    companion object {
        fun schedule(context: Context) {
            val request = PeriodicWorkRequestBuilder<RefreshWorker>(15, TimeUnit.MINUTES)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork("refresh", ExistingPeriodicWorkPolicy.KEEP, request)
        }
    }
}
