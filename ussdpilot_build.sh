#!/data/data/com.termux/files/usr/bin/bash
# UssdPilot - build an accessibility-based M-Pesa USSD autopilot APK entirely in Termux.
# No PC, no Android Studio, no Gradle. Run inside Termux.
#
# How it works:
#  - You save entries: name + menu steps (e.g. "3,2") + payee numbers (e.g. till "174478").
#  - Tap entry -> enter amount -> app dials plain *334# -> accessibility service types the
#    steps into the USSD popup, presses Send, waits for the next screen, repeats.
#  - Stops before the M-Pesa PIN: YOU type the PIN. The app never sees it.
set -e

pkg install -y openjdk-17 aapt apksigner dx findutils wget >/dev/null 2>&1 || true
for t in java javac dx aapt apksigner keytool; do
  command -v "$t" >/dev/null 2>&1 || {
    echo "ERROR: $t is missing. Install manually with:"
    echo "  pkg install -y openjdk-17 aapt apksigner dx findutils wget"
    exit 1
  }
done

# ---- 1. Find an android.jar (framework stubs) ----
AJ=""
[ -f "$PREFIX/share/aapt/android.jar" ] && AJ="$PREFIX/share/aapt/android.jar"   # ships with Termux aapt
[ -z "$AJ" ] && AJ=$(find ~ "$PREFIX" -name android.jar 2>/dev/null | head -1)   # SlimeDroid etc.
[ -z "$AJ" ] && {   # fallback: download API 33 platform stub
  mkdir -p ~/android-sdk/platforms/android-33
  AJ=~/android-sdk/platforms/android-33/android.jar
  [ -f "$AJ" ] || wget -q -O "$AJ" https://github.com/Sable/android-platforms/raw/master/android-33/android.jar
}
[ -f "$AJ" ] || { echo "android.jar not found"; exit 1; }
echo "Using android.jar: $AJ"

P=~/UssdPilot
rm -rf "$P"; mkdir -p "$P/src/com/heavens/ussdpilot" "$P/res/xml" "$P/obj" "$P/build"
cd "$P"

# ---- 2. Manifest ----
cat > AndroidManifest.xml <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.heavens.ussdpilot">
  <uses-sdk android:minSdkVersion="23" android:targetSdkVersion="28"/>
  <application android:label="UssdPilot">
    <activity android:name=".MainActivity" android:exported="true">
      <intent-filter>
        <action android:name="android.intent.action.MAIN"/>
        <category android:name="android.intent.category.LAUNCHER"/>
      </intent-filter>
    </activity>
    <service android:name=".AutoPilotService"
        android:exported="false"
        android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE">
      <intent-filter>
        <action android:name="android.accessibilityservice.AccessibilityService"/>
      </intent-filter>
      <meta-data android:name="android.accessibilityservice"
          android:resource="@xml/ussdpilot"/>
    </service>
  </application>
</manifest>
EOF

# ---- 3. Accessibility service config ----
cat > res/xml/ussdpilot.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<accessibility-service xmlns:android="http://schemas.android.com/apk/res/android"
    android:accessibilityEventTypes="typeWindowContentChanged|typeWindowStateChanged|typeViewFocused"
    android:accessibilityFeedbackType="feedbackGeneric"
    android:canRetrieveWindowContent="true" />
EOF

# ---- 4. Main activity ----
cat > src/com/heavens/ussdpilot/MainActivity.java <<'EOF'
package com.heavens.ussdpilot;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Bundle;
import android.provider.Settings;
import android.text.InputType;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.util.ArrayList;
import java.util.List;

public class MainActivity extends Activity {
  SharedPreferences sp;
  LinearLayout list;
  TextView status;

  protected void onCreate(Bundle b) {
    super.onCreate(b);
    sp = getSharedPreferences("p", 0);
    LinearLayout root = new LinearLayout(this);
    root.setOrientation(LinearLayout.VERTICAL);
    root.setPadding(24, 24, 24, 24);

    status = new TextView(this);
    root.addView(status);

    Button acc = new Button(this);
    acc.setText("Enable AutoPilot (Accessibility)");
    acc.setOnClickListener(new View.OnClickListener() {
      public void onClick(View v) { startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)); }
    });
    root.addView(acc);

    Button add = new Button(this);
    add.setText("+ Add");
    add.setOnClickListener(new View.OnClickListener() {
      public void onClick(View v) { edit(-1); }
    });
    root.addView(add);

    list = new LinearLayout(this);
    list.setOrientation(LinearLayout.VERTICAL);
    ScrollView sv = new ScrollView(this);
    sv.addView(list);
    root.addView(sv);
    setContentView(root);
    render();
  }

  protected void onResume() {
    super.onResume();
    status.setText("AutoPilot: " + (AutoPilotService.isRunning() ? "ON" : "OFF - tap the button above to enable it"));
  }

  String[] items() {
    String s = sp.getString("items", "");
    return s.isEmpty() ? new String[0] : s.split("\n");
  }

  void save(String[] a) {
    StringBuilder sb = new StringBuilder();
    for (String x : a) { if (sb.length() > 0) sb.append("\n"); sb.append(x); }
    sp.edit().putString("items", sb.toString()).apply();
    render();
  }

  void render() {
    list.removeAllViews();
    final String[] a = items();
    for (int i = 0; i < a.length; i++) {
      final int idx = i;
      String[] p = a[i].split("\t", 3);
      String name = p[0];
      String steps = p.length > 1 ? p[1] : "";
      String payee = p.length > 2 ? p[2] : "";
      Button bt = new Button(this);
      bt.setText(name + "   [" + steps + (payee.isEmpty() ? "" : " + " + payee) + "]");
      bt.setOnClickListener(new View.OnClickListener() {
        public void onClick(View v) { pay(idx); }
      });
      bt.setOnLongClickListener(new View.OnLongClickListener() {
        public boolean onLongClick(View v) { edit(idx); return true; }
      });
      list.addView(bt);
    }
  }

  void pay(final int idx) {
    final String[] a = items();
    String[] p = a[idx].split("\t", 3);
    final String steps = p.length > 1 ? p[1] : "";
    final String payee = p.length > 2 ? p[2] : "";
    final EditText e = new EditText(this);
    e.setInputType(InputType.TYPE_CLASS_NUMBER);
    e.setHint("Amount (leave empty to skip)");
    new AlertDialog.Builder(this).setTitle("Pay: " + p[0]).setView(e)
      .setPositiveButton("Go", new DialogInterface.OnClickListener() {
        public void onClick(DialogInterface d, int w) {
          List<String> q = new ArrayList<String>();
          for (String s : steps.split(",")) if (s.trim().length() > 0) q.add(s.trim());
          for (String s : payee.split(",")) if (s.trim().length() > 0) q.add(s.trim());
          String amount = e.getText().toString().trim();
          if (amount.length() > 0) q.add(amount);
          if (q.size() == 0) return;
          if (!AutoPilotService.isRunning()) {
            Toast.makeText(MainActivity.this, "Enable AutoPilot first (tap the Accessibility button)", Toast.LENGTH_LONG).show();
            return;
          }
          dial();
          AutoPilotService.begin(q);
        }
      }).show();
  }

  void dial() {
    startActivity(new Intent(Intent.ACTION_DIAL, Uri.parse("tel:" + Uri.encode("*334#"))));
  }

  void edit(final int idx) {
    final String[] a = items();
    final EditText n = new EditText(this);
    n.setHint("Name e.g. Naivas / Mom / KPLC");
    final EditText s = new EditText(this);
    s.setHint("Steps (menu numbers, comma-sep) e.g. 3,2");
    final EditText q = new EditText(this);
    q.setHint("Payee (comma-sep) e.g. 174478 or 170551,1234567890");
    if (idx >= 0) {
      String[] p = a[idx].split("\t", 3);
      n.setText(p[0]);
      if (p.length > 1) s.setText(p[1]);
      if (p.length > 2) q.setText(p[2]);
    }
    LinearLayout l = new LinearLayout(this);
    l.setOrientation(LinearLayout.VERTICAL);
    l.addView(n); l.addView(s); l.addView(q);
    AlertDialog.Builder bd = new AlertDialog.Builder(this).setView(l)
      .setPositiveButton("Save", new DialogInterface.OnClickListener() {
        public void onClick(DialogInterface d, int w) {
          String line = n.getText().toString().trim() + "\t"
            + s.getText().toString().trim() + "\t"
            + q.getText().toString().trim();
          String[] r;
          if (idx >= 0) { r = a; r[idx] = line; }
          else { r = new String[a.length + 1]; System.arraycopy(a, 0, r, 0, a.length); r[a.length] = line; }
          save(r);
        }
      });
    if (idx >= 0) bd.setNeutralButton("Delete", new DialogInterface.OnClickListener() {
      public void onClick(DialogInterface d, int w) {
        String[] r = new String[a.length - 1];
        for (int i = 0, k = 0; i < a.length; i++) if (i != idx) r[k++] = a[i];
        save(r);
      }
    });
    bd.show();
  }
}
EOF

# ---- 5. Accessibility service ----
cat > src/com/heavens/ussdpilot/AutoPilotService.java <<'EOF'
package com.heavens.ussdpilot;

import android.accessibilityservice.AccessibilityService;
import android.app.Notification;
import android.app.NotificationManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;

import java.util.List;

public class AutoPilotService extends AccessibilityService {
  static AutoPilotService instance;
  private static final String TAG = "UssdPilot";

  interface Matcher { boolean matches(AccessibilityNodeInfo n); }

  private final Handler handler = new Handler(Looper.getMainLooper());
  private List<String> queue;
  private int idx;
  private boolean active;
  private String lastSig;
  private long lastSentAt;

  public static boolean isRunning() { return instance != null; }

  public static void begin(List<String> steps) {
    if (instance != null) instance.runQueue(steps);
  }

  @Override public void onServiceConnected() { instance = this; }

  @Override public void onDestroy() { instance = null; active = false; }

  @Override public void onInterrupt() { finish("stopped"); }

  @Override public void onAccessibilityEvent(AccessibilityEvent event) {
    if (active) handler.post(new Runnable() { public void run() { maybeSend(); } });
  }

  void runQueue(List<String> q) {
    queue = q; idx = 0; active = true; lastSig = null;
    lastSentAt = System.currentTimeMillis();
    notifyMsg("Armed - " + q.size() + " steps: " + q.toString());
    handler.post(new Runnable() { public void run() { poll(); } });
  }

  private void poll() {
    if (!active) return;
    maybeSend();
    if (!active) return;
    if (idx < queue.size() && System.currentTimeMillis() - lastSentAt > 20000) {
      finish("no response for 20s - session may have timed out");
      return;
    }
    if (active) handler.postDelayed(new Runnable() { public void run() { poll(); } }, 1200);
  }

  private void maybeSend() {
    if (!active) return;
    if (idx >= queue.size()) { finish("All steps sent - enter your M-Pesa PIN now"); return; }
    AccessibilityNodeInfo root = getRootInActiveWindow();
    if (root == null) return;
    try {
      AccessibilityNodeInfo input = findFirst(root, new Matcher() {
        public boolean matches(AccessibilityNodeInfo n) {
          String cls = n.getClassName() == null ? "" : n.getClassName().toString();
          return cls.contains("EditText") || n.isEditable();
        }
      });
      if (input == null) return;
      AccessibilityNodeInfo button = findFirst(root, new Matcher() {
        public boolean matches(AccessibilityNodeInfo n) {
          String cls = n.getClassName() == null ? "" : n.getClassName().toString();
          if (!cls.contains("Button")) return false;
          CharSequence t = n.getText();
          if (t == null) return false;
          String s = t.toString().trim().toLowerCase();
          return s.equals("send") || s.equals("ok") || s.equals("done")
            || s.contains("发送") || s.contains("确定") || s.contains("确认");
        }
      });
      if (button == null) return;
      String sig = signature(root);
      if (sig.equals(lastSig)) return;
      lastSig = sig;
      Bundle args = new Bundle();
      args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, queue.get(idx));
      input.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args);
      button.performAction(AccessibilityNodeInfo.ACTION_CLICK);
      Log.i(TAG, "sent " + (idx + 1) + "/" + queue.size() + ": " + queue.get(idx));
      idx++;
      lastSentAt = System.currentTimeMillis();
      if (idx >= queue.size()) finish("All steps sent - enter your M-Pesa PIN now");
    } finally {
      root.recycle();
    }
  }

  private AccessibilityNodeInfo findFirst(AccessibilityNodeInfo node, Matcher m) {
    if (m.matches(node)) return node;
    for (int i = 0; i < node.getChildCount(); i++) {
      AccessibilityNodeInfo r = findFirst(node.getChild(i), m);
      if (r != null) return r;
    }
    return null;
  }

  private String signature(AccessibilityNodeInfo node) {
    StringBuilder sb = new StringBuilder();
    collect(node, sb);
    return sb.toString();
  }

  private void collect(AccessibilityNodeInfo node, StringBuilder sb) {
    CharSequence t = node.getText();
    if (t != null) sb.append(t).append('|');
    for (int i = 0; i < node.getChildCount(); i++) collect(node.getChild(i), sb);
  }

  void finish(String msg) {
    active = false;
    notifyMsg(msg);
  }

  private void notifyMsg(String msg) {
    NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
    Notification n = new Notification.Builder(this)
      .setContentTitle("UssdPilot AutoPilot")
      .setContentText(msg)
      .setSmallIcon(android.R.drawable.ic_menu_info_details)
      .setAutoCancel(true)
      .build();
    nm.notify(1, n);
  }
}
EOF

# ---- 6. Compile (javac - ecj on Termux is broken/old, javac works fine) ----
javac -source 1.8 -target 1.8 -cp "$AJ" -d obj src/com/heavens/ussdpilot/*.java

# ---- 7. Dex ----
dx --dex --output build/classes.dex obj

# ---- 8. Package ----
aapt package -f -M AndroidManifest.xml -S res -I "$AJ" -F unsigned.apk
(cd build && aapt add ../unsigned.apk classes.dex)

# ---- 9. Sign ----
[ -f ~/debug.keystore ] || keytool -genkeypair -keystore ~/debug.keystore -storepass android \
  -keypass android -alias key -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=UssdPilot"
apksigner sign --ks ~/debug.keystore --ks-pass pass:android --key-pass pass:android \
  --ks-key-alias key --out UssdPilot.apk unsigned.apk
apksigner verify --print-certs UssdPilot.apk | head -3

# ---- 10. Copy to Downloads and hint how to install ----
mkdir -p ~/storage/Download 2>/dev/null || true
cp UssdPilot.apk ~/storage/Download/UssdPilot.apk 2>/dev/null && echo "Copied to ~/storage/Download/UssdPilot.apk" \
  || echo "APK at $P/UssdPilot.apk (run termux-setup-storage to copy to Downloads)"
echo "Install it now with:  termux-open $P/UssdPilot.apk"
echo "First test: enable AutoPilot, add an entry with steps '1' and no payee, tap it, watch the popup."
echo DONE
