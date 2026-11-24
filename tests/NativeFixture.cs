using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Web.Script.Serialization;
class NativeFixture {
    static int Main(string[] args) {
        var json = new JavaScriptSerializer();
        if (!Path.GetFileName(Environment.GetCommandLineArgs()[0]).Equals("vswhere.exe", StringComparison.OrdinalIgnoreCase)) {
            File.WriteAllText(Environment.GetEnvironmentVariable("PR37_INSTALL_ARGS"), json.Serialize(args));
            return 0;
        }
        File.AppendAllText(Environment.GetEnvironmentVariable("PR37_ARGS"), json.Serialize(args) + Environment.NewLine);
        var instances = json.Deserialize<List<Dictionary<string, object>>>(File.ReadAllText(Environment.GetEnvironmentVariable("PR37_INSTANCES")));
        int products = Array.IndexOf(args, "-products");
        if (products >= 0) {
            var accepted = args.Skip(products + 1).TakeWhile(a => !a.StartsWith("-")).ToArray();
            if (!accepted.Contains("*")) instances = instances.Where(i => accepted.Contains((string)i["productId"])).ToList();
        }
        instances = instances.OrderByDescending(i => new Version((string)i["installationVersion"])).ToList();
        if (args.Contains("-latest")) instances = instances.Take(1).ToList();
        int property = Array.IndexOf(args, "-property");
        if (property >= 0) foreach (var instance in instances) Console.WriteLine(instance[args[property+1]]);
        else Console.WriteLine(json.Serialize(instances));
        return 0;
    }
}
