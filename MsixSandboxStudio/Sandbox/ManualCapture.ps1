# Recording window for manual installs. Runs INSIDE the sandbox as the "installer" of the conversion
# template: the MSIX Packaging Tool captures every change made while this window is open.
#   Finish recording -> exit 0, the tool builds the package
#   Cancel           -> exit 1602, the conversion fails and nothing is packaged
# Writes no files: anything written during the recording would end up in the package.

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$jobDir = 'C:\MsixStudio\Job'
$inputDir = Join-Path $jobDir 'input'
$job = Get-Content (Join-Path $jobDir 'job.json') -Raw -Encoding UTF8 | ConvertFrom-Json

$bg = [System.Drawing.Color]::FromArgb(20, 28, 50)
$fg = [System.Drawing.Color]::FromArgb(230, 234, 242)
$muted = [System.Drawing.Color]::FromArgb(138, 150, 176)
$accent = [System.Drawing.Color]::FromArgb(124, 92, 255)

function New-Button([string]$Text, [System.Drawing.Color]$Back) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $Back
    $b.ForeColor = [System.Drawing.Color]::White
    $b.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
    $b.Height = 36
    $b.Cursor = 'Hand'
    $b
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'MSIX recording'
$form.FormBorderStyle = 'FixedToolWindow'
$form.TopMost = $true
$form.BackColor = $bg
$form.ForeColor = $fg
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.ClientSize = New-Object System.Drawing.Size(420, 400)
$form.StartPosition = 'Manual'
$area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object System.Drawing.Point(($area.Right - 440), ($area.Bottom - 420))

$dot = New-Object System.Windows.Forms.Label
$dot.Text = [char]0x25CF + '  RECORDING'
$dot.ForeColor = [System.Drawing.Color]::FromArgb(248, 113, 113)
$dot.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$dot.SetBounds(20, 16, 380, 20)
$form.Controls.Add($dot)

$title = New-Object System.Windows.Forms.Label
$title.Text = $job.DisplayName
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 14)
$title.SetBounds(20, 38, 380, 30)
$form.Controls.Add($title)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = "Install and configure the app now: run setups, accept licenses, change settings, start it once if needed.`n`nEverything you change in this sandbox goes into the package, so keep it to the app."
$hint.ForeColor = $muted
$hint.SetBounds(20, 74, 380, 100)
$form.Controls.Add($hint)

$list = New-Object System.Windows.Forms.ListBox
$list.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 48)
$list.ForeColor = $fg
$list.BorderStyle = 'FixedSingle'
$list.SetBounds(20, 178, 280, 92)
$files = @(Get-ChildItem $inputDir -File -ErrorAction SilentlyContinue)
foreach ($f in $files) { [void]$list.Items.Add($f.Name) }
if ($files) { $list.SelectedIndex = 0 } else { [void]$list.Items.Add('(no installer provided)') }
$form.Controls.Add($list)

$run = New-Button 'Run' $accent
$run.SetBounds(310, 178, 90, 36)
$run.Enabled = [bool]$files
$run.Add_Click({
    $file = Join-Path $inputDir $list.SelectedItem
    if ([IO.Path]::GetExtension($file) -eq '.msi') { Start-Process msiexec.exe -ArgumentList '/i', "`"$file`"" }
    else { Start-Process $file }
})
$form.Controls.Add($run)

$explore = New-Button 'Folder' ([System.Drawing.Color]::FromArgb(51, 65, 85))
$explore.SetBounds(310, 234, 90, 36)
$explore.Add_Click({ Start-Process explorer.exe $inputDir })
$form.Controls.Add($explore)

$finish = New-Button 'Finish recording' ([System.Drawing.Color]::FromArgb(16, 124, 65))
$finish.SetBounds(20, 300, 380, 40)
$finish.Add_Click({
    $answer = [System.Windows.Forms.MessageBox]::Show($form, 'Is the installation complete? The package is built from everything recorded so far.', 'Finish recording', 'YesNo', 'Question')
    if ($answer -eq 'Yes') { $form.Tag = 0; $form.Close() }
})
$form.Controls.Add($finish)

$cancel = New-Object System.Windows.Forms.LinkLabel
$cancel.Text = 'Cancel without package'
$cancel.LinkColor = $muted
$cancel.SetBounds(20, 352, 380, 24)
$cancel.TextAlign = 'MiddleCenter'
$cancel.Add_LinkClicked({ $form.Tag = 1602; $form.Close() })
$form.Controls.Add($cancel)

# Closing with the X counts as cancel.
$form.Tag = 1602
$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
exit [int]$form.Tag
