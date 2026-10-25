#!/data/data/com.termux/files/usr/bin/bash
# TillPay - build a simple M-Pesa "save tills/paybills + send money" APK entirely in Termux.
# No PC, no Android Studio, no Gradle. Run inside Termux.
set -e

pkg install -y openjdk-17 aapt apksigner dx ecj findutils >/dev/null 2>&1 || true

# ---- 1. Find an android.jar (framework stubs) ----
AJ=""
[ -f "$PREFIX/share/aapt/android.jar" ] && AJ="$PREFIX/share/aapt/android.jar"   # ships with Termux aapt
[ -z "$AJ" ] && AJ=$(find ~ "$PREFIX" -name android.jar 2>/dev/null | head -1)   # SlimeDroid etc.
[ -z "$AJ" ] && {   # fallback: download API 33 platform stub
  mkdir -p ~/android-sdk/platforms/android-33
  AJ=~/android-sdk/platforms/android-33/android.jar
  [ -f "$AJ" ] || wget -q -O "$AJ" https://github.com/Sable/android-platforms/raw/master/android-33/android.jar
}
[ -f "$AJ" ] || { echo "android.jar not found - tell me what SlimeDroid used"; exit 1; }
echo "Using android.jar: $AJ"

P=~/TillPay
rm -rf "$P"; mkdir -p "$P/src/com/heavens/tillpay" "$P/obj" "$P/build"
cd "$P"

# ---- 2. Manifest ----
cat > AndroidManifest.xml <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.heavens.tillpay">
  <uses-sdk android:minSdkVersion="23" android:targetSdkVersion="28"/>
  <application android:label="TillPay">
    <activity android:name=".MainActivity" android:exported="true">
      <intent-filter>
        <action android:name="android.intent.action.MAIN"/>
        <category android:name="android.intent.category.LAUNCHER"/>
      </intent-filter>
    </activity>
  </application>
</manifest>
EOF

cat > src/com/heavens/tillpay/MainActivity.java <<'EOF'
package com.heavens.tillpay;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Bundle;
import android.text.Editable;
import android.text.InputType;
import android.text.TextWatcher;
import android.view.View;
import android.widget.AdapterView;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Spinner;

public class MainActivity extends Activity {
  SharedPreferences sp;
  LinearLayout list;

  // M-Pesa *334# dial templates ($A = amount, asked at pay time)
  static final String P_SEND = "*334*1*1*"; // + phone + *$A#  (send to M-Pesa)
  static final String P_NET  = "*334*1*2*"; // + phone + *$A#  (send to other networks)
  static final String P_BILL = "*334*4*1*"; // + paybill*account + *$A#
  static final String P_TILL = "*334*4*2*"; // + till + *$A#
  static final String SUFFIX = "*$A#";

  protected void onCreate(Bundle b) {
    super.onCreate(b);
    sp = getSharedPreferences("p", 0);
    LinearLayout root = new LinearLayout(this);
    root.setOrientation(LinearLayout.VERTICAL);
    root.setPadding(24, 24, 24, 24);
    Button add = new Button(this);
    add.setText("+ Add");
    add.setOnClickListener(new View.OnClickListener() {
      public void onClick(View v) { edit(-1); }
    });
    list = new LinearLayout(this);
    list.setOrientation(LinearLayout.VERTICAL);
    ScrollView sv = new ScrollView(this);
    sv.addView(list);
    root.addView(add);
    root.addView(sv);
    setContentView(root);
    render();
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

  static String typeOf(int pos) {
    if (pos == 0) return "S";
    if (pos == 1) return "N";
    if (pos == 2) return "P";
    if (pos == 3) return "T";
    return "X";
  }

  static int typeIndex(String t) {
    if (t.equals("S")) return 0;
    if (t.equals("N")) return 1;
    if (t.equals("P")) return 2;
    if (t.equals("T")) return 3;
    return 4;
  }

  String tag(String t) {
    if (t.equals("S")) return "Send";
    if (t.equals("N")) return "Send(net)";
    if (t.equals("P")) return "Paybill";
    if (t.equals("T")) return "Till";
    return "";
  }

  String buildCode(String t, String f1, String f2) {
    if (t.equals("S")) return P_SEND + f1 + SUFFIX;
    if (t.equals("N")) return P_NET + f1 + SUFFIX;
    if (t.equals("P")) return P_BILL + f1 + "*" + f2 + SUFFIX;
    if (t.equals("T")) return P_TILL + f1 + SUFFIX;
    return "";
  }

  // Parse a stored dial code back into [type, field1, field2]. Returns X if unrecognized.
  void parseCode(String code, String[] out) {
    out[0] = "X"; out[1] = ""; out[2] = "";
    if (code != null && code.endsWith(SUFFIX)) {
      String m = code.substring(0, code.length() - SUFFIX.length());
      if (m.startsWith(P_BILL)) {
        out[0] = "P";
        String[] kv = m.substring(P_BILL.length()).split("\\*", 2);
        out[1] = kv[0];
        out[2] = kv.length > 1 ? kv[1] : "";
        return;
      }
      if (m.startsWith(P_TILL)) { out[0] = "T"; out[1] = m.substring(P_TILL.length()); return; }
      if (m.startsWith(P_SEND)) { out[0] = "S"; out[1] = m.substring(P_SEND.length()); return; }
      if (m.startsWith(P_NET))  { out[0] = "N"; out[1] = m.substring(P_NET.length()); return; }
    }
  }

  void render() {
    list.removeAllViews();
    final String[] a = items();
    for (int i = 0; i < a.length; i++) {
      final int idx = i;
      String[] p = a[i].split("\t", 3);
      String name = p[0];
      String type, code;
      if (p.length >= 3) { type = p[1]; code = p[2]; }
      else if (p.length == 2) { type = "T"; code = p[1]; }   // legacy name\tcode = till
      else { type = "X"; code = ""; }
      final String cd = code;
      Button bt = new Button(this);
      bt.setText(name + (tag(type).isEmpty() ? "" : "  [" + tag(type) + "]"));
      bt.setOnClickListener(new View.OnClickListener() {
        public void onClick(View v) { askAmount(cd); }
      });
      bt.setOnLongClickListener(new View.OnLongClickListener() {
        public boolean onLongClick(View v) { edit(idx); return true; }
      });
      list.addView(bt);
    }
    // built-in shortcuts
    addBuiltIn("M-Pesa menu", "*334#");
    addBuiltIn("Balance", "*334*0#");
  }

  void addBuiltIn(final String name, final String code) {
    Button bt = new Button(this);
    bt.setText(name + "  [menu]");
    bt.setOnClickListener(new View.OnClickListener() {
      public void onClick(View v) { askAmount(code); }
    });
    list.addView(bt);
  }

  void askAmount(final String code) {
    if (!code.contains("$A")) { dial(code); return; }
    final EditText e = new EditText(this);
    e.setInputType(InputType.TYPE_CLASS_NUMBER);
    e.setHint("Amount");
    new AlertDialog.Builder(this).setTitle("Amount").setView(e)
      .setPositiveButton("Pay", new DialogInterface.OnClickListener() {
        public void onClick(DialogInterface d, int w) {
          dial(code.replace("$A", e.getText().toString().trim()));
        }
      }).show();
  }

  void dial(String code) {
    // ACTION_DIAL: opens the dialer with the code filled in; user taps call.
    // Reliable across devices, needs NO permission.
    // For auto-dial you'd need ACTION_CALL + CALL_PHONE permission instead.
    startActivity(new Intent(Intent.ACTION_DIAL, Uri.parse("tel:" + Uri.encode(code))));
  }

  void edit(final int idx) {
    final String[] a = items();
    String name = "", type = "X", code = "";
    if (idx >= 0) {
      String[] p = a[idx].split("\t", 3);
      name = p[0];
      if (p.length >= 3) { type = p[1]; code = p[2]; }
      else if (p.length == 2) { type = "T"; code = p[1]; }
    }
    final String[] parsed = new String[3];
    parseCode(code, parsed);
    final boolean matched = !parsed[0].equals("X");

    final Spinner spType = new Spinner(this);
    ArrayAdapter<String> sa = new ArrayAdapter<String>(this, android.R.layout.simple_spinner_item,
      new String[]{"Send Money (M-Pesa)", "Send Money (other network)", "Pay Bill", "Buy Goods (Till)", "Custom code"});
    sa.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
    spType.setAdapter(sa);
    spType.setSelection(matched ? typeIndex(parsed[0]) : 4);

    final EditText n = new EditText(this);
    n.setHint("Name e.g. Mom / Naivas / KPLC");
    n.setText(name);

    final EditText f1 = new EditText(this);
    f1.setInputType(InputType.TYPE_CLASS_NUMBER);
    final EditText f2 = new EditText(this);
    f2.setInputType(InputType.TYPE_CLASS_NUMBER);
    f1.setText(parsed[1]);
    f2.setText(parsed[2]);

    final EditText codeE = new EditText(this);
    codeE.setHint("dial code (auto-built; edit if your line needs another format)");
    codeE.setText(code);

    final boolean[] manual = {false};   // user typed the code directly
    final boolean[] self = {false};      // we are updating the code ourselves
    final int[] lastPos = {spType.getSelectedItemPosition()};

    final Runnable updateCode = new Runnable() {
      public void run() {
        String t = typeOf(spType.getSelectedItemPosition());
        if (t.equals("S") || t.equals("N")) f1.setHint("Phone e.g. 0712345678");
        else if (t.equals("P")) f1.setHint("Paybill number e.g. 170551");
        else if (t.equals("T")) f1.setHint("Till number e.g. 174478");
        else f1.setHint("not used");
        f2.setVisibility(t.equals("P") ? View.VISIBLE : View.GONE);
        f2.setHint("Account number e.g. 1234567890");
        if (t.equals("X") || manual[0]) return;
        self[0] = true;
        codeE.setText(buildCode(t, f1.getText().toString(), f2.getText().toString()));
        self[0] = false;
      }
    };

    LinearLayout l = new LinearLayout(this);
    l.setOrientation(LinearLayout.VERTICAL);
    l.addView(spType);
    l.addView(n);
    l.addView(f1);
    l.addView(f2);
    l.addView(codeE);

    codeE.addTextChangedListener(new TextWatcher() {
      public void beforeTextChanged(CharSequence s, int start, int count, int after) {}
      public void onTextChanged(CharSequence s, int start, int before, int count) {}
      public void afterTextChanged(Editable s) { if (!self[0]) manual[0] = true; }
    });
    if (!matched) manual[0] = true;   // keep a custom dial code as typed

    TextWatcher tw = new TextWatcher() {
      public void beforeTextChanged(CharSequence s, int start, int count, int after) {}
      public void onTextChanged(CharSequence s, int start, int before, int count) {}
      public void afterTextChanged(Editable s) { updateCode.run(); }
    };
    f1.addTextChangedListener(tw);
    f2.addTextChangedListener(tw);
    spType.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
      public void onItemSelected(AdapterView<?> parent, View view, int position, long id) {
        if (position != lastPos[0]) { lastPos[0] = position; manual[0] = false; }
        updateCode.run();
      }
      public void onNothingSelected(AdapterView<?> parent) {}
    });
    updateCode.run();

    AlertDialog.Builder bd = new AlertDialog.Builder(this).setView(l)
      .setPositiveButton("Save", new DialogInterface.OnClickListener() {
        public void onClick(DialogInterface d, int w) {
          String line = n.getText().toString().trim() + "\t"
            + typeOf(spType.getSelectedItemPosition()) + "\t"
            + codeE.getText().toString().trim();
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

# ---- 3. Compile (ecj = Eclipse Java compiler) ----
ecj -source 1.8 -target 1.8 -cp "$AJ" -d obj src/com/heavens/tillpay/MainActivity.java

# ---- 4. Dex (dx is deprecated but works; d8 is the modern alternative) ----
dx --dex --output build/classes.dex obj

# ---- 5. Package ----
aapt package -f -M AndroidManifest.xml -I "$AJ" -F unsigned.apk
(cd build && aapt add ../unsigned.apk classes.dex)

# ---- 6. Sign ----
[ -f ~/debug.keystore ] || keytool -genkeypair -keystore ~/debug.keystore -storepass android \
  -keypass android -alias key -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=TillPay"
apksigner sign --ks ~/debug.keystore --ks-pass pass:android --key-pass pass:android \
  --ks-key-alias key --out TillPay.apk unsigned.apk
apksigner verify --print-certs TillPay.apk | head -3

# ---- 7. Copy to Downloads ----
mkdir -p ~/storage/Download 2>/dev/null || true
cp TillPay.apk ~/storage/Download/TillPay.apk 2>/dev/null && echo "Copied to ~/storage/Download/TillPay.apk" \
  || echo "APK at $P/TillPay.apk (run termux-setup-storage to copy to Downloads)"
echo DONE
