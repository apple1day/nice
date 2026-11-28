package com.anxiong.nicevideos;

import android.annotation.TargetApi;
import android.graphics.Rect;
import android.os.SystemClock;
import android.text.TextUtils;
import android.view.View;
import android.view.ViewGroup;
import android.view.inspector.WindowInspector;
import android.widget.EditText;
import android.widget.TextView;

import androidx.test.core.app.ActivityScenario;

import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.Predicate;

/** Works with the tested application's views, including dialogs, independently of the emulator's active system window. */
@TargetApi(29)
final class TestAppWindows {
    private final ActivityScenario<MainActivity> scene;

    TestAppWindows(ActivityScenario<MainActivity> scene) { this.scene = scene; }

    void click(String label) {
        interact(label, v -> v instanceof TextView && label.contentEquals(((TextView)v).getText())
                && v.isEnabled() && v.isClickable() && v.performClick());
    }

    void expectText(String fragment) {
        interact(fragment, v -> v instanceof TextView && ((TextView)v).getText().toString().contains(fragment));
    }

    void enterText(String hint, String value) {
        interact(hint, v -> {
            if (!(v instanceof EditText) || !TextUtils.equals(hint, ((EditText)v).getHint()) || !v.isEnabled()) return false;
            ((EditText)v).setText(value);
            return true;
        });
    }

    private void interact(String expected, Predicate<View> action) {
        long deadline = SystemClock.elapsedRealtime() + 12000;
        AtomicBoolean done = new AtomicBoolean();
        do {
            scene.onActivity(activity -> {
                // Check the latest attached window first; an AlertDialog has its own DecorView.
                List<View> roots = WindowInspector.getGlobalWindowViews();
                for (int i = roots.size() - 1; i >= 0; i--) {
                    if (findAndAct(roots.get(i), action)) {
                        done.set(true);
                        return;
                    }
                }
            });
            if (done.get()) return;
            SystemClock.sleep(80);
        } while (SystemClock.elapsedRealtime() < deadline);
        throw new AssertionError("Missing visible app control: " + expected);
    }

    private static boolean findAndAct(View v, Predicate<View> action) {
        if (!v.isShown() || !v.getGlobalVisibleRect(new Rect())) return false;
        if (action.test(v)) return true;
        if (v instanceof ViewGroup) {
            ViewGroup group = (ViewGroup)v;
            for (int i = 0; i < group.getChildCount(); i++) {
                if (findAndAct(group.getChildAt(i), action)) return true;
            }
        }
        return false;
    }
}
