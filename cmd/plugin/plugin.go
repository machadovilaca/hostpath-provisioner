/*
Copyright 2021 The hostpath provisioner Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package main

import (
	"flag"
	"os"

	"k8s.io/klog/v2"
	"sigs.k8s.io/controller-runtime/pkg/manager/signals"

	"kubevirt.io/hostpath-provisioner/pkg/hostpath"
)

func init() {
}

func main() {
	defer klog.Flush()
	cfg := &hostpath.Config{}
	var dataDir string
	klog.InitFlags(nil)
	flag.Set("logtostderr", "true")
	flag.StringVar(&cfg.Endpoint, "endpoint", "unix://tmp/csi.sock", "CSI endpoint")
	flag.StringVar(&cfg.DriverName, "drivername", "hostpath.csi.kubevirt.io", "name of the driver")
	flag.StringVar(&dataDir, "datadir", "/csi-data-dir", "storage pool name/path tupels that indicate which storage pool name is associated with which path, in JSON format. Example: [{\"name\":\"local\",\"path\":\"/var/hpvolumes\"}]")
	flag.StringVar(&cfg.NodeID, "nodeid", "", "node id")
	flag.StringVar(&cfg.Version, "version", "", "version of the plugin")
	flag.Parse()

	klog.V(1).Info("Starting Prometheus metrics endpoint server")
	hostpath.RunPrometheusServer(":8080")

	klog.V(1).Infof("Starting new HostPathDriver, config: %v", *cfg)
	ctx := signals.SetupSignalHandler()
	driver, err := hostpath.NewHostPathDriver(ctx, cfg, dataDir)
	if err != nil {
		klog.V(1).Infof("Failed to initialize driver: %s", err.Error())
		os.Exit(1)
	}

	if err := driver.Run(); err != nil {
		klog.V(1).Infof("Failed to run driver: %s", err.Error())
		os.Exit(1)

	}
}
