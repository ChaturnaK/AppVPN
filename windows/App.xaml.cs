using System.Windows;

namespace AppVPN;

public partial class App : Application
{
    static Mutex? single;

    void OnStartup(object sender, StartupEventArgs e)
    {
        if (e.Args is ["--selftest", var index]) Environment.Exit(Proxy.SelfTest(int.Parse(index)));
        if (e.Args is ["--selftest-profiles", var dir]) Environment.Exit(ProfileStore.SelfTest(dir));
        // ponytail: a second launch just exits. Bring the first window to the front instead if that confuses anyone.
        single = new Mutex(true, "AppVPN.single-instance", out bool first);
        if (!first) Environment.Exit(0);
        new MainWindow().Show();
    }
}
