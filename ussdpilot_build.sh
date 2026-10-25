#!/data/data/com.termux/files/usr/bin/bash
# UssdPilot - build an accessibility-based M-Pesa USSD autopilot APK entirely in Termux.
# No PC, no Android Studio, no Gradle. Run inside Termux.
#
# How it works:
#  - Entries: name + menu steps (e.g. "3,2") + payee numbers (e.g. till "174478",
#    paybill "170551,1234567890", or a phone picked from Contacts) + optional M-Pesa PIN.
#  - Tap entry -> enter amount -> app dials plain *334# -> accessibility service types the
#    steps into the USSD popup, presses Send, waits for the next screen, repeats.
#  - With a PIN stored, it types the PIN when the PIN prompt appears. Without one, it stops
#    and you type the PIN yourself. The PIN is stored on this device only - never sent anywhere.
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
import android.database.Cursor;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Bundle;
import android.provider.ContactsContract;
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
  EditText payeeField;   // payee field of the open Add/Edit dialog (for contact picking)

  private static final int PICK = 1;
  private static final int GREEN = 0xFF2E7D32;
  private static final int RED = 0xFFC62828;

  protected void onCreate(Bundle b) {
    super.onCreate(b);
    sp = getSharedPreferences("p", 0);
    LinearLayout root = new LinearLayout(this);
    root.setOrientation(LinearLayout.VERTICAL);
    root.setPadding(24, 24, 24, 24);

    TextView title = new TextView(this);
    title.setText("UssdPilot");
    title.setTextSize(24);
    title.setTypeface(Typeface.DEFAULT_BOLD);
    title.setPadding(0, 0, 0, 4);
    root.addView(title);

    TextView sub = new TextView(this);
    sub.setText("M-Pesa USSD autopilot - test build");
    sub.setTextSize(13);
    sub.setPadding(0, 0, 0, 12);
    root.addView(sub);

    status = new TextView(this);
    status.setPadding(0, 8, 0, 8);
    root.addView(status);

    Button acc = new Button(this);
    acc.setText("Enable AutoPilot (Accessibility)");
    acc.setPadding(16, 8, 16, 8);
    acc.setOnClickListener(new View.OnClickListener() {
      public void onClick(View v) { startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)); }
    });
    root.addView(acc);

    Button about = new Button(this);
    about.setText("About / Credits");
    about.setPadding(16, 8, 16, 8);
    about.setOnClickListener(new View.OnClickListener() {
      public void onClick(View v) { showAbout(); }
    });
    root.addView(about);

    Button add = new Button(this);
    add.setText("+ Add");
    add.setPadding(16, 8, 16, 8);
    add.setOnClickListener(new View.OnClickListener() {
      public void onClick(View v) { edit(-1); }
    });
    root.addView(add);

    list = new LinearLayout(this);
    list.setOrientation(LinearLayout.VERTICAL);
    ScrollView sv = new ScrollView(this);
    sv.addView(list);
    root.addView(sv);

    TextView footer = new TextView(this);
    footer.setText("Optional PIN: stored on this phone only. Do not use on a device you don't fully trust.");
    footer.setTextSize(11);
    footer.setPadding(0, 24, 0, 0);
    root.addView(footer);

    setContentView(root);
    render();
  }

  protected void onResume() {
    super.onResume();
    if (AutoPilotService.isRunning()) {
      status.setText("AutoPilot: ON");
      status.setTextColor(GREEN);
    } else {
      status.setText("AutoPilot: OFF - tap the button above to enable it");
      status.setTextColor(RED);
    }
  }

  void showAbout() {
    TextView tv = new TextView(this);
    tv.setPadding(40, 30, 40, 10);
    tv.setText("Creator: heavensassunder\n"
      + "WhatsApp: +254769204848\n"
      + "GitHub: github.com/heavensassunder/mpesa\n\n"
      + "Personal test project. Your M-Pesa PIN never leaves this device - it is only "
      + "typed into the USSD session on this phone.");
    tv.setTextSize(14);
    new AlertDialog.Builder(this).setTitle("About UssdPilot").setView(tv)
      .setPositiveButton("Close", null).show();
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
      String[] p = a[i].split("\t", 4);
      String name = p[0];
      String steps = p.length > 1 ? p[1] : "";
      String payee = p.length > 2 ? p[2] : "";
      boolean pinOn = p.length > 3 && p[3].length() > 0;
      Button bt = new Button(this);
      bt.setPadding(16, 10, 16, 10);
      bt.setText(name + "   [" + steps + (payee.isEmpty() ? "" : " + " + payee) + "]   "
        + (pinOn ? "PIN: on" : "PIN: off"));
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
    String[] p = a[idx].split("\t", 4);
    final String steps = p.length > 1 ? p[1] : "";
    final String payee = p.length > 2 ? p[2] : "";
    final String pin = p.length > 3 ? p[3] : "";
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
          AutoPilotService.begin(q, pin);
        }
      }).show();
  }

  void dial() {
    startActivity(new Intent(Intent.ACTION_DIAL, Uri.parse("tel:" + Uri.encode("*334#"))));
  }

  void pickContact() {
    try {
      startActivityForResult(new Intent(Intent.ACTION_PICK,
        ContactsContract.CommonDataKinds.Phone.CONTENT_URI), PICK);
    } catch (Exception ex) {
      Toast.makeText(this, "No contacts app found", Toast.LENGTH_SHORT).show();
    }
  }

  @Override protected void onActivityResult(int req, int res, Intent data) {
    super.onActivityResult(req, res, data);
    if (req == PICK && res == RESULT_OK && data != null && payeeField != null) {
      String num = null;
      Cursor c = null;
      try {
        c = getContentResolver().query(data.getData(), null, null, null, null);
        if (c != null && c.moveToFirst()) {
          int i = c.getColumnIndex(ContactsContract.CommonDataKinds.Phone.NUMBER);
          if (i >= 0) num = c.getString(i);
        }
      } catch (Exception ex) {
        Toast.makeText(this, "Could not read contact", Toast.LENGTH_SHORT).show();
      } finally {
        if (c != null) c.close();
      }
      if (num != null && num.trim().length() > 0) payeeField.setText(num.trim());
    }
  }

  void edit(final int idx) {
    final String[] a = items();
    final EditText n = new EditText(this);
    n.setHint("Name e.g. Naivas / Mom / KPLC");
    final EditText s = new EditText(this);
    s.setHint("Steps (menu numbers, comma-sep) e.g. 3,2");
    payeeField = new EditText(this);
    payeeField.setHint("Payee (comma-sep) e.g. 174478 or 170551,1234567890");
    payeeField.setInputType(InputType.TYPE_CLASS_TEXT);
    final EditText pin = new EditText(this);
    pin.setInputType(InputType.TYPE_CLASS_NUMBER | InputType.TYPE_TEXT_VARIATION_PASSWORD);
    pin.setHint("PIN (optional) - stored on this phone only");
    if (idx >= 0) {
      String[] p = a[idx].split("\t", 4);
      n.setText(p[0]);
      if (p.length > 1) s.setText(p[1]);
      if (p.length > 2) payeeField.setText(p[2]);
      if (p.length > 3) pin.setText(p[3]);
    }
    Button pick = new Button(this);
    pick.setText("Pick");
    pick.setOnClickListener(new View.OnClickListener() {
      public void onClick(View v) { pickContact(); }
    });
    LinearLayout payeeRow = new LinearLayout(this);
    payeeRow.setOrientation(LinearLayout.HORIZONTAL);
    payeeRow.addView(payeeField, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));
    payeeRow.addView(pick, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT));

    LinearLayout l = new LinearLayout(this);
    l.setOrientation(LinearLayout.VERTICAL);
    l.addView(n);
    l.addView(s);
    l.addView(payeeRow);
    l.addView(pin);
    AlertDialog.Builder bd = new AlertDialog.Builder(this).setView(l)
      .setPositiveButton("Save", new DialogInterface.OnClickListener() {
        public void onClick(DialogInterface d, int w) {
          String line = n.getText().toString().trim() + "\t"
            + s.getText().toString().trim() + "\t"
            + payeeField.getText().toString().trim() + "\t"
            + pin.getText().toString().trim();
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
  private String pin;
  private boolean active;
  private boolean awaitPin;
  private String lastSig;
  private long lastSentAt;

  public static boolean isRunning() { return instance != null; }

  public static void begin(List<String> steps, String pin) {
    if (instance != null) instance.runQueue(steps, pin);
  }

  @Override public void onServiceConnected() { instance = this; }

  @Override public void onDestroy() { instance = null; active = false; }

  @Override public void onInterrupt() { finish("stopped"); }

  @Override public void onAccessibilityEvent(AccessibilityEvent event) {
    if (active) handler.post(new Runnable() { public void run() { maybeSend(); } });
  }

  void runQueue(List<String> q, String p) {
    queue = q; idx = 0;
    pin = (p == null || p.trim().length() == 0) ? null : p.trim();
    active = true; awaitPin = false; lastSig = null;
    lastSentAt = System.currentTimeMillis();
    notifyMsg("Armed - " + q.size() + " steps" + (pin != null ? " + PIN" : ""));
    handler.post(new Runnable() { public void run() { poll(); } });
  }

  private void poll() {
    if (!active) return;
    maybeSend();
    if (!active) return;
    if (System.currentTimeMillis() - lastSentAt > 20000) {
      if (idx < queue.size()) finish("no response for 20s - session may have timed out");
      else if (awaitPin) finish("PIN prompt not detected in time - enter your PIN manually");
      else finish("All steps sent - enter your M-Pesa PIN now");
      return;
    }
    if (active) handler.postDelayed(new Runnable() { public void run() { poll(); } }, 1200);
  }

  private void maybeSend() {
    if (!active) return;
    AccessibilityNodeInfo root = getRootInActiveWindow();
    if (root == null) return;
    try {
      AccessibilityNodeInfo input = findFirst(root, new Matcher() {
        public boolean matches(AccessibilityNodeInfo n) {
          String cls = n.getClassName() == null ? "" : n.getClassName().toString();
          return cls.contains("EditText") || n.isEditable();
        }
      });
      AccessibilityNodeInfo button = findFirst(root, new Matcher() {
        public boolean matches(AccessibilityNodeInfo n) {
          String cls = n.getClassName() == null ? "" : n.getClassName().toString();
          if (!cls.contains("Button")) return false;
          CharSequence t = n.getText();
          if (t == null) return false;
          String s = t.toString().trim().toLowerCase();
          return s.equals("send") || s.equals("ok") || s.equals("done") || s.equals("submit")
            || s.contains("发送") || s.contains("确定") || s.contains("确认") || s.contains("提交");
        }
      });
      String sig = signature(root);

      if (idx >= queue.size()) {
        // All queued steps sent. With a stored PIN: stay active and wait for the PIN prompt screen.
        if (!awaitPin) { finish("All steps sent - enter your M-Pesa PIN now"); return; }
        if (input == null || button == null) return;   // loading/intermediate screen - keep waiting
        if (sig.equals(lastSig)) return;               // same screen - PIN prompt not up yet
        if (sig.toLowerCase().contains("pin")) {
          sendPin(input, button);
        } else {
          lastSig = sig;   // new screen but not the PIN prompt yet - never type the PIN here, keep waiting
        }
        return;
      }

      if (input == null || button == null) return;   // popup not up yet or closed
      if (sig.equals(lastSig)) return;               // same screen - wait for the session to refresh
      lastSig = sig;
      Bundle args = new Bundle();
      args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, queue.get(idx));
      input.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args);
      button.performAction(AccessibilityNodeInfo.ACTION_CLICK);
      Log.i(TAG, "sent " + (idx + 1) + "/" + queue.size() + ": " + queue.get(idx));
      idx++;
      lastSentAt = System.currentTimeMillis();
      if (idx >= queue.size()) {
        if (pin != null) {
          awaitPin = true;   // stay active: keep watching for the PIN prompt (must NOT finish here)
          notifyMsg("Steps sent - waiting for the PIN prompt...");
          Log.i(TAG, "all steps sent, awaiting PIN prompt");
        } else {
          finish("All steps sent - enter your M-Pesa PIN now");
        }
      }
    } finally {
      root.recycle();
    }
  }

  private void sendPin(AccessibilityNodeInfo input, AccessibilityNodeInfo button) {
    Bundle args = new Bundle();
    args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, pin);
    input.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args);
    button.performAction(AccessibilityNodeInfo.ACTION_CLICK);
    Log.i(TAG, "PIN typed and sent");
    lastSentAt = System.currentTimeMillis();
    finish("Payment sent - check your SMS confirmation");
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
echo "Test order: 1) enable AutoPilot  2) add entry steps '1', PIN empty, tap it  3) then retry with PIN stored."
echo DONE
