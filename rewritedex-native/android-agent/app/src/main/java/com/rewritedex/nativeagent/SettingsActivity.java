package com.rewritedex.nativeagent;

import android.content.SharedPreferences;
import android.os.Bundle;
import android.view.View;
import android.widget.AdapterView;
import android.widget.ArrayAdapter;
import android.widget.Spinner;
import androidx.appcompat.app.AppCompatActivity;
import androidx.appcompat.widget.SwitchCompat;
import android.widget.CompoundButton;
import android.content.Intent;
import android.provider.Settings;
import android.widget.Button;
import android.widget.Toast;

public class SettingsActivity extends AppCompatActivity {
    private SwitchCompat themeSwitch;
    private Spinner qualityProfileSpinner;
    private SharedPreferences sharedPreferences;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        // Load existing settings first
        sharedPreferences = getSharedPreferences("prefs", MODE_PRIVATE);
        setTheme(sharedPreferences.getBoolean("dark_theme", false) ? R.style.AppTheme_Dark : R.style.AppTheme);
        super.onCreate(savedInstanceState);
        setContentView(R.layout.settings_activity);

        themeSwitch = findViewById(R.id.themeSwitch);
        qualityProfileSpinner = findViewById(R.id.qualityProfileSpinner);

        // Initialize theme switch state
        themeSwitch.setChecked(sharedPreferences.getBoolean("dark_theme", false));
        themeSwitch.setOnCheckedChangeListener(new CompoundButton.OnCheckedChangeListener() {
            @Override
            public void onCheckedChanged(CompoundButton buttonView, boolean isChecked) {
                sharedPreferences.edit().putBoolean("dark_theme", isChecked).apply();
                Toast.makeText(SettingsActivity.this, "Theme will apply after restart", Toast.LENGTH_SHORT).show();
            }
        });

        // Load quality profiles into the spinner
        ArrayAdapter<CharSequence> adapter = ArrayAdapter.createFromResource(this, R.array.quality_profiles, android.R.layout.simple_spinner_item);
        adapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item);
        qualityProfileSpinner.setAdapter(adapter);

        int selected = sharedPreferences.getInt("quality_profile", 1);
        qualityProfileSpinner.setSelection(selected);
        qualityProfileSpinner.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
            @Override
            public void onItemSelected(AdapterView<?> parent, View view, int position, long id) {
                // Save the selected profile to preferences
                sharedPreferences.edit().putInt("quality_profile", position).apply();
                // Notify service via broadcast to apply changes without restart
                Intent intent = new Intent(SettingsActivity.this, DexAgentService.class);
                intent.setAction("com.rewritedex.nativeagent.ACTION_APPLY_SETTINGS");
                intent.putExtra("quality_profile", position);
                startService(intent);
                Toast.makeText(SettingsActivity.this, "Quality profile saved", Toast.LENGTH_SHORT).show();
            }

            @Override
            public void onNothingSelected(AdapterView<?> parent) {
                // Do nothing
            }
        });

        // Advanced: quick link to notification access settings
        findViewById(R.id.notificationSettingsButton).setOnClickListener(v -> {
            try {
                Intent intent = new Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS);
                startActivity(intent);
            } catch (Exception e) {
                Toast.makeText(SettingsActivity.this, "Could not open notification settings", Toast.LENGTH_SHORT).show();
            }
        });

        // Wire restart button - ask service to restart (or self-stop so controller can relaunch)
        Button restartBtn = (Button) findViewById(R.id.restartServiceButton);
        if (restartBtn != null) {
            restartBtn.setOnClickListener(v -> {
                Intent svc = new Intent(SettingsActivity.this, DexAgentService.class);
                svc.setAction("com.rewritedex.nativeagent.ACTION_RESTART_AGENT");
                startService(svc);
                Toast.makeText(SettingsActivity.this, "Agent restart requested", Toast.LENGTH_SHORT).show();
                finish();
            });
        }

        // Export diagnostics: surface a simple status dump + direct user to logs dir on device
        Button exportBtn = (Button) findViewById(R.id.exportLogsButton);
        if (exportBtn != null) {
            exportBtn.setOnClickListener(v -> {
                // Fire a request to agent (which can log) and guide user
                Intent svc = new Intent(SettingsActivity.this, DexAgentService.class);
                svc.setAction("com.rewritedex.nativeagent.ACTION_EXPORT_DIAGNOSTICS");
                startService(svc);
                Toast.makeText(SettingsActivity.this,
                    "Diagnostics requested. Check /sdcard/Download/RewriteDEX or use host tray 'Export diagnostics'.",
                    Toast.LENGTH_LONG).show();
            });
        }
    }
}