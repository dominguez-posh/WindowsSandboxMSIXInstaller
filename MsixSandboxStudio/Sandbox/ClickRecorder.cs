// Screen and click recorder for the MSIX Recorder (compiled with Add-Type inside the sandbox).
// - A frame thread keeps the latest screen image (every 200 ms) and saves one timeline frame per interval.
// - A low-level mouse hook takes the frame from just BEFORE each click (shows what was clicked),
//   a worker thread looks up window and UI element (UI Automation), marks the click and saves the step.
// The hook must be installed on a thread with a message loop (the recorder's UI thread).
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Automation;

namespace MsixStudio
{
    public class ClickStep
    {
        public int Index;
        public double Seconds;
        public string Time;
        public string Button;
        public int X;
        public int Y;
        public string Window;
        public string Process;
        public string Element;
        public string ElementType;
        public string Image;
    }

    public class TimelineFrame
    {
        public double Seconds;
        public string Image;
    }

    public class ClickRecorder : IDisposable
    {
        delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)] struct POINT { public int X; public int Y; }
        [StructLayout(LayoutKind.Sequential)] struct MSLLHOOKSTRUCT { public POINT Pt; public uint MouseData; public uint Flags; public uint Time; public IntPtr Extra; }

        [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr module, uint thread);
        [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);
        [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT pt);
        [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);

        const int WH_MOUSE_LL = 14;
        const int WM_LBUTTONDOWN = 0x0201, WM_RBUTTONDOWN = 0x0204;

        readonly string stepDir, frameDir;
        readonly int ownPid = System.Diagnostics.Process.GetCurrentProcess().Id;
        readonly int frameInterval;
        readonly int maxFrameWidth;
        readonly HookProc proc;
        readonly object frameLock = new object();
        readonly BlockingCollection<Tuple<DateTime, POINT, string, Bitmap>> queue = new BlockingCollection<Tuple<DateTime, POINT, string, Bitmap>>();
        readonly Rectangle screen = System.Windows.Forms.SystemInformation.VirtualScreen;
        IntPtr hook = IntPtr.Zero;
        Bitmap latest;
        Thread frameThread, worker;
        volatile bool running;
        DateTime started;

        public readonly List<ClickStep> Steps = new List<ClickStep>();
        public readonly List<TimelineFrame> Frames = new List<TimelineFrame>();
        public string LastError;

        public ClickRecorder(string outputDir, int frameIntervalMs, int maxWidth)
        {
            stepDir = Path.Combine(outputDir, "steps");
            frameDir = Path.Combine(outputDir, "frames");
            Directory.CreateDirectory(stepDir);
            Directory.CreateDirectory(frameDir);
            frameInterval = frameIntervalMs;
            maxFrameWidth = maxWidth;
            proc = HookCallback;   // keep the delegate alive
        }

        public int ClickCount { get { lock (Steps) { return Steps.Count; } } }

        public void Start()
        {
            started = DateTime.Now;
            running = true;
            frameThread = new Thread(FrameLoop) { IsBackground = true };
            frameThread.Start();
            worker = new Thread(WorkLoop) { IsBackground = true };
            worker.Start();
            hook = SetWindowsHookEx(WH_MOUSE_LL, proc, GetModuleHandle(null), 0);
            if (hook == IntPtr.Zero) LastError = "Mouse hook failed: " + Marshal.GetLastWin32Error();
        }

        public void Stop()
        {
            if (hook != IntPtr.Zero) { UnhookWindowsHookEx(hook); hook = IntPtr.Zero; }
            running = false;
            queue.CompleteAdding();
            if (worker != null) worker.Join(15000);
            if (frameThread != null) frameThread.Join(3000);
        }

        public void Dispose()
        {
            Stop();
            lock (frameLock) { if (latest != null) latest.Dispose(); latest = null; }
        }

        Bitmap Capture()
        {
            var bmp = new Bitmap(screen.Width, screen.Height, PixelFormat.Format24bppRgb);
            using (var g = Graphics.FromImage(bmp)) { g.CopyFromScreen(screen.Left, screen.Top, 0, 0, screen.Size); }
            return bmp;
        }

        static ImageCodecInfo Jpeg { get { return ImageCodecInfo.GetImageEncoders().First(c => c.FormatID == ImageFormat.Jpeg.Guid); } }

        static void SaveJpeg(Bitmap bmp, string path, long quality)
        {
            using (var p = new EncoderParameters(1))
            {
                p.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, quality);
                bmp.Save(path, Jpeg, p);
            }
        }

        Bitmap Scale(Bitmap source)
        {
            if (source.Width <= maxFrameWidth) return (Bitmap)source.Clone();
            int h = (int)(source.Height * (maxFrameWidth / (double)source.Width));
            var scaled = new Bitmap(maxFrameWidth, h, PixelFormat.Format24bppRgb);
            using (var g = Graphics.FromImage(scaled)) { g.InterpolationMode = InterpolationMode.HighQualityBilinear; g.DrawImage(source, 0, 0, maxFrameWidth, h); }
            return scaled;
        }

        void FrameLoop()
        {
            var lastFrame = DateTime.MinValue;
            int n = 0;
            while (running)
            {
                try
                {
                    var bmp = Capture();
                    lock (frameLock) { if (latest != null) latest.Dispose(); latest = bmp; }
                    if ((DateTime.Now - lastFrame).TotalMilliseconds >= frameInterval)
                    {
                        lastFrame = DateTime.Now;
                        Bitmap copy;
                        lock (frameLock) { copy = Scale(latest); }
                        using (copy)
                        {
                            string name = string.Format("frame-{0:D5}.jpg", ++n);
                            SaveJpeg(copy, Path.Combine(frameDir, name), 55L);
                            lock (Frames) { Frames.Add(new TimelineFrame { Seconds = Math.Round((lastFrame - started).TotalSeconds, 1), Image = "frames/" + name }); }
                        }
                    }
                }
                catch (Exception e) { LastError = e.Message; }
                Thread.Sleep(200);
            }
        }

        IntPtr HookCallback(int code, IntPtr wParam, IntPtr lParam)
        {
            if (code >= 0 && running)
            {
                int msg = wParam.ToInt32();
                if (msg == WM_LBUTTONDOWN || msg == WM_RBUTTONDOWN)
                {
                    var info = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
                    Bitmap snap = null;
                    lock (frameLock) { if (latest != null) snap = (Bitmap)latest.Clone(); }
                    queue.Add(Tuple.Create(DateTime.Now, info.Pt, msg == WM_LBUTTONDOWN ? "Left" : "Right", snap));
                }
            }
            return CallNextHookEx(hook, code, wParam, lParam);
        }

        void WorkLoop()
        {
            foreach (var item in queue.GetConsumingEnumerable())
            {
                using (var bmp = item.Item4)
                {
                    try { HandleClick(item.Item1, item.Item2, item.Item3, bmp); }
                    catch (Exception e) { LastError = e.Message; }
                }
            }
        }

        void HandleClick(DateTime time, POINT pt, string button, Bitmap bmp)
        {
            IntPtr root = GetAncestor(WindowFromPoint(pt), 2);   // GA_ROOT
            uint pid;
            GetWindowThreadProcessId(root, out pid);
            if (pid == ownPid) return;   // clicks on the recorder itself are not part of the installation

            var title = new StringBuilder(512);
            GetWindowText(root, title, title.Capacity);
            string processName = "";
            try { processName = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { }

            string element = "", elementType = "";
            try
            {
                var el = AutomationElement.FromPoint(new System.Windows.Point(pt.X, pt.Y));
                if (el != null)
                {
                    element = el.Current.Name ?? "";
                    elementType = el.Current.LocalizedControlType ?? "";
                    if (string.IsNullOrEmpty(element)) element = el.Current.AutomationId ?? "";
                }
            }
            catch { }

            int index;
            lock (Steps) { index = Steps.Count + 1; }
            string file = null;
            if (bmp != null)
            {
                int x = pt.X - screen.Left, y = pt.Y - screen.Top;
                using (var g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    using (var fill = new SolidBrush(Color.FromArgb(70, 239, 68, 68)))
                    using (var pen = new Pen(Color.FromArgb(230, 239, 68, 68), 4))
                    {
                        g.FillEllipse(fill, x - 26, y - 26, 52, 52);
                        g.DrawEllipse(pen, x - 26, y - 26, 52, 52);
                    }
                    using (var font = new Font("Segoe UI", 13, FontStyle.Bold))
                    using (var badge = new SolidBrush(Color.FromArgb(239, 68, 68)))
                    {
                        g.FillEllipse(badge, x + 18, y - 40, 30, 30);
                        var s = index.ToString();
                        var size = g.MeasureString(s, font);
                        g.DrawString(s, font, Brushes.White, x + 33 - size.Width / 2, y - 25 - size.Height / 2);
                    }
                }
                using (var scaled = Scale(bmp))
                {
                    file = string.Format("steps/step-{0:D3}.jpg", index);
                    SaveJpeg(scaled, Path.Combine(stepDir, Path.GetFileName(file)), 80L);
                }
            }

            lock (Steps)
            {
                Steps.Add(new ClickStep
                {
                    Index = index,
                    Seconds = Math.Round((time - started).TotalSeconds, 1),
                    Time = time.ToString("HH:mm:ss"),
                    Button = button,
                    X = pt.X, Y = pt.Y,
                    Window = title.ToString(),
                    Process = processName,
                    Element = element,
                    ElementType = elementType,
                    Image = file
                });
            }
        }
    }
}
