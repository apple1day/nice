package com.anxiong.nicevideos;

import android.app.Activity;
import android.app.AlertDialog;
import android.view.View;
import android.view.ViewGroup;
import android.widget.AdapterView;
import android.widget.ArrayAdapter;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.Spinner;
import android.widget.TextView;

/** Edit projection, packing of the source image and the viewport independently. */
final class VrOptionsDialog {
    interface Apply { void accept(VrFormat format, int fov); }

    private static final VrFormat.Projection[] PROJECTIONS = {
            VrFormat.Projection.EQUIRECT_180, VrFormat.Projection.EQUIRECT_360,
            VrFormat.Projection.FISHEYE_180, VrFormat.Projection.FLAT
    };
    private static final VrFormat.Layout[] PANO_LAYOUTS = {
            VrFormat.Layout.SBS_FULL, VrFormat.Layout.TOP_BOTTOM, VrFormat.Layout.MONO
    };
    private static final VrFormat.Layout[] FLAT_LAYOUTS = {
            VrFormat.Layout.SBS_FULL, VrFormat.Layout.SBS_HALF, VrFormat.Layout.TOP_BOTTOM, VrFormat.Layout.MONO
    };

    static String projectionName(VrFormat.Projection projection) {
        switch (projection) {
            case EQUIRECT_180: return "180° 全景";
            case EQUIRECT_360: return "360° 全景";
            case FISHEYE_180: return "180° 鱼眼";
            default: return "平面影院";
        }
    }

    static String layoutName(VrFormat format) {
        switch (format.layout) {
            case SBS_FULL: return format.projection == VrFormat.Projection.FLAT ? "全宽 SBS" : "左右分屏";
            case SBS_HALF: return format.projection == VrFormat.Projection.FLAT ? "半宽 SBS" : "左右分屏";
            case TOP_BOTTOM: return "上下分屏";
            default: return "单画面";
        }
    }

    static AlertDialog create(Activity activity, VrFormat current, float fov, Apply apply, Runnable details) {
        int padding = Math.round(20 * activity.getResources().getDisplayMetrics().density);
        ScrollView scroll = new ScrollView(activity);
        LinearLayout panel = new LinearLayout(activity);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setPadding(padding, padding / 2, padding, 0);
        scroll.addView(panel);
        Spinner projection = field(activity, panel, "投影");
        String[] projectionNames = new String[PROJECTIONS.length];
        for (int i = 0; i < PROJECTIONS.length; i++) projectionNames[i] = projectionName(PROJECTIONS[i]);
        choices(activity, projection, projectionNames, index(PROJECTIONS, current.projection));

        Spinner layout = field(activity, panel, "片源排布");
        boolean flat = current.projection == VrFormat.Projection.FLAT;
        fillLayouts(activity, layout, flat, current.layout);
        Spinner display = field(activity, panel, "观看方式");
        choices(activity, display, new String[]{"单屏观看", "双眼眼镜"}, current.headset ? 1 : 0);
        VrViewerSettings gestures = VrViewerSettings.read(activity);
        Spinner quality = field(activity, panel, "VR 渲染清晰度");
        choices(activity, quality, VrViewerSettings.Quality.values(), gestures.quality.ordinal());
        Spinner tap = field(activity, panel, "画面双击");
        choices(activity, tap, VrViewerSettings.DoubleTap.values(), gestures.doubleTap.ordinal());
        LinearLayout zoom = new LinearLayout(activity);
        zoom.setOrientation(LinearLayout.VERTICAL);
        panel.addView(zoom);
        Spinner pinch = field(activity, zoom, "双指缩放幅度");
        choices(activity, pinch, VrViewerSettings.Pinch.values(), gestures.pinch.ordinal());
        TextView angleLabel = caption(activity, zoom, "");
        SeekBar angle = new SeekBar(activity);
        angle.setMax(65);
        angle.setContentDescription("视场角");
        angle.setProgress(Math.round(fov) - 45);
        zoom.addView(angle);
        angleLabel.setText("视场角  " + (angle.getProgress() + 45) + "°");
        angle.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            public void onStartTrackingTouch(SeekBar bar) {}
            public void onStopTrackingTouch(SeekBar bar) {}
            public void onProgressChanged(SeekBar bar, int p, boolean user) {
                angleLabel.setText("视场角  " + (p + 45) + "°");
            }
        });
        zoom.setVisibility(flat ? View.GONE : View.VISIBLE);
        projection.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
            boolean wasFlat = flat;
            public void onNothingSelected(AdapterView<?> parent) {}
            public void onItemSelected(AdapterView<?> parent, View v, int position, long id) {
                boolean nextFlat = PROJECTIONS[position] == VrFormat.Projection.FLAT;
                if (nextFlat == wasFlat) return;
                VrFormat.Layout selected = (wasFlat ? FLAT_LAYOUTS : PANO_LAYOUTS)[layout.getSelectedItemPosition()];
                wasFlat = nextFlat;
                fillLayouts(activity, layout, nextFlat, selected);
                zoom.setVisibility(nextFlat ? View.GONE : View.VISIBLE);
            }
        });
        return new AlertDialog.Builder(activity).setTitle("VR 设置").setView(scroll)
                .setPositiveButton("应用", (d, w) -> {
                    VrFormat.Projection p = PROJECTIONS[projection.getSelectedItemPosition()];
                    VrFormat.Layout[] layouts = p == VrFormat.Projection.FLAT ? FLAT_LAYOUTS : PANO_LAYOUTS;
                    new VrViewerSettings((VrViewerSettings.DoubleTap) tap.getSelectedItem(),
                            (VrViewerSettings.Pinch) pinch.getSelectedItem(),
                            (VrViewerSettings.Quality) quality.getSelectedItem()).save(activity);
                    apply.accept(new VrFormat(p, layouts[layout.getSelectedItemPosition()], display.getSelectedItemPosition() == 1),
                            angle.getProgress() + 45);
                }).setNegativeButton("取消", null).setNeutralButton("片源信息", (d, w) -> details.run()).create();
    }

    private static void fillLayouts(Activity a, Spinner spinner, boolean flat, VrFormat.Layout selected) {
        VrFormat.Layout[] layouts = flat ? FLAT_LAYOUTS : PANO_LAYOUTS;
        choices(a, spinner, flat ? new String[]{"全宽 SBS", "半宽 SBS", "上下分屏（上左下右）", "单画面（2D）"}
                : new String[]{"左右分屏（左眼在左）", "上下分屏（左眼在上）", "单画面（2D）"}, index(layouts, selected));
    }

    private static int index(Object[] objects, Object search) {
        for (int i = 0; i < objects.length; i++) if (objects[i] == search) return i;
        return 0;
    }

    private static TextView caption(Activity a, LinearLayout parent, String text) {
        TextView label = new TextView(a);
        label.setText(text);
        label.setTextSize(14);
        label.setPadding(0, Math.round(6 * a.getResources().getDisplayMetrics().density), 0, 0);
        parent.addView(label);
        return label;
    }

    private static Spinner field(Activity a, LinearLayout parent, String title) {
        caption(a, parent, title);
        Spinner spinner = new Spinner(a, Spinner.MODE_DROPDOWN);
        spinner.setContentDescription(title);
        parent.addView(spinner, ViewGroup.LayoutParams.MATCH_PARENT,
                Math.round(44 * a.getResources().getDisplayMetrics().density));
        return spinner;
    }

    private static <T> void choices(Activity a, Spinner s, T[] labels, int selected) {
        ArrayAdapter<T> adapter = new ArrayAdapter<>(a, android.R.layout.simple_spinner_item, labels);
        adapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
        s.setAdapter(adapter);
        s.setSelection(selected, false);
    }
}
