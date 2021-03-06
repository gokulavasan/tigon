/*
 * Copyright © 2014 Cask Data, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */

package co.cask.tigon.internal.app.runtime.distributed;

import co.cask.tigon.app.guice.DataFabricFacadeModule;
import co.cask.tigon.app.guice.MetricsClientRuntimeModule;
import co.cask.tigon.app.program.Program;
import co.cask.tigon.app.program.Programs;
import co.cask.tigon.conf.CConfiguration;
import co.cask.tigon.data.runtime.DataFabricModules;
import co.cask.tigon.guice.ConfigModule;
import co.cask.tigon.guice.DiscoveryRuntimeModule;
import co.cask.tigon.guice.IOModule;
import co.cask.tigon.guice.LocationRuntimeModule;
import co.cask.tigon.guice.ZKClientModule;
import co.cask.tigon.internal.app.queue.QueueReaderFactory;
import co.cask.tigon.internal.app.runtime.AbstractListener;
import co.cask.tigon.internal.app.runtime.Arguments;
import co.cask.tigon.internal.app.runtime.BasicArguments;
import co.cask.tigon.internal.app.runtime.ProgramController;
import co.cask.tigon.internal.app.runtime.ProgramOptionConstants;
import co.cask.tigon.internal.app.runtime.ProgramOptions;
import co.cask.tigon.internal.app.runtime.ProgramResourceReporter;
import co.cask.tigon.internal.app.runtime.ProgramRunner;
import co.cask.tigon.internal.app.runtime.SimpleProgramOptions;
import co.cask.tigon.metrics.MetricsCollectionService;
import com.google.common.base.Predicates;
import com.google.common.base.Throwables;
import com.google.common.collect.ImmutableMap;
import com.google.common.collect.ImmutableSet;
import com.google.common.collect.Maps;
import com.google.common.io.Files;
import com.google.common.util.concurrent.Futures;
import com.google.common.util.concurrent.MoreExecutors;
import com.google.common.util.concurrent.SettableFuture;
import com.google.gson.Gson;
import com.google.inject.AbstractModule;
import com.google.inject.Guice;
import com.google.inject.Inject;
import com.google.inject.Injector;
import com.google.inject.Module;
import com.google.inject.PrivateModule;
import com.google.inject.Scopes;
import com.google.inject.name.Named;
import com.google.inject.name.Names;
import com.google.inject.util.Modules;
import org.apache.commons.cli.CommandLine;
import org.apache.commons.cli.Option;
import org.apache.commons.cli.Options;
import org.apache.commons.cli.ParseException;
import org.apache.commons.cli.PosixParser;
import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.security.UserGroupInformation;
import org.apache.twill.api.Command;
import org.apache.twill.api.ServiceAnnouncer;
import org.apache.twill.api.TwillContext;
import org.apache.twill.api.TwillRunnable;
import org.apache.twill.api.TwillRunnableSpecification;
import org.apache.twill.common.Cancellable;
import org.apache.twill.common.Services;
import org.apache.twill.filesystem.LocalLocationFactory;
import org.apache.twill.filesystem.Location;
import org.apache.twill.filesystem.LocationFactory;
import org.apache.twill.zookeeper.ZKClientService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.File;
import java.io.IOException;
import java.util.Map;
import java.util.concurrent.CountDownLatch;

/**
 * A {@link org.apache.twill.api.TwillRunnable} for running a program through a {@link ProgramRunner}.
 *
 * @param <T> The {@link ProgramRunner} type.
 */
public abstract class AbstractProgramTwillRunnable<T extends ProgramRunner> implements TwillRunnable {

  private static final Logger LOG = LoggerFactory.getLogger(AbstractProgramTwillRunnable.class);

  private String name;
  private String hConfName;
  private String cConfName;

  private Injector injector;
  private Program program;
  private ProgramOptions programOpts;
  private ProgramController controller;
  private Configuration hConf;
  private CConfiguration cConf;
  private ZKClientService zkClientService;
  private MetricsCollectionService metricsCollectionService;
  private ProgramResourceReporter resourceReporter;
  private CountDownLatch runlatch;

  protected AbstractProgramTwillRunnable(String name, String hConfName, String cConfName) {
    this.name = name;
    this.hConfName = hConfName;
    this.cConfName = cConfName;
  }

  protected abstract Class<T> getProgramClass();

  /**
   * Provides sets of configurations to put into the specification. Children classes can override
   * this method to provides custom configurations.
   */
  protected Map<String, String> getConfigs() {
    return ImmutableMap.of();
  }

  @Override
  public TwillRunnableSpecification configure() {
    return TwillRunnableSpecification.Builder.with()
      .setName(name)
      .withConfigs(ImmutableMap.<String, String>builder()
                     .put("hConf", hConfName)
                     .put("cConf", cConfName)
                     .putAll(getConfigs())
                     .build())
      .build();
  }

  @Override
  public void initialize(TwillContext context) {
    runlatch = new CountDownLatch(1);
    name = context.getSpecification().getName();
    Map<String, String> configs = context.getSpecification().getConfigs();

    LOG.info("Initialize runnable: " + name);
    try {
      CommandLine cmdLine = parseArgs(context.getApplicationArguments());

      // Loads configurations
      hConf = new Configuration();
      hConf.clear();
      hConf.addResource(new File(configs.get("hConf")).toURI().toURL());

      UserGroupInformation.setConfiguration(hConf);

      cConf = CConfiguration.create();
      cConf.clear();
      cConf.addResource(new File(configs.get("cConf")).toURI().toURL());

      injector = Guice.createInjector(createModule(context));

      zkClientService = injector.getInstance(ZKClientService.class);
      metricsCollectionService = injector.getInstance(MetricsCollectionService.class);

      try {
        program = injector.getInstance(ProgramFactory.class)
          .create(cmdLine.getOptionValue(RunnableOptions.JAR));
      } catch (IOException e) {
        throw Throwables.propagate(e);
      }

      Arguments runtimeArguments
        = new Gson().fromJson(cmdLine.getOptionValue(RunnableOptions.RUNTIME_ARGS), BasicArguments.class);
      programOpts =  new SimpleProgramOptions(name, createProgramArguments(context, configs), runtimeArguments);
      resourceReporter = new ProgramRunnableResourceReporter(program, metricsCollectionService, context);

      LOG.info("Runnable initialized: " + name);
    } catch (Throwable t) {
      LOG.error(t.getMessage(), t);
      throw Throwables.propagate(t);
    }
  }

  @Override
  public void handleCommand(Command command) throws Exception {
    // need to make sure controller exists before handling the command
    runlatch.await();
    if (ProgramCommands.SUSPEND.equals(command)) {
      controller.suspend().get();
      return;
    }
    if (ProgramCommands.RESUME.equals(command)) {
      controller.resume().get();
      return;
    }
    if (ProgramOptionConstants.INSTANCES.equals(command.getCommand())) {
      int instances = Integer.parseInt(command.getOptions().get("count"));
      controller.command(ProgramOptionConstants.INSTANCES, instances).get();
      return;
    }
    LOG.warn("Ignore unsupported command: " + command);
  }

  @Override
  public void stop() {
    try {
      LOG.info("Stopping runnable: {}", name);
      controller.stop().get();
    } catch (Exception e) {
      LOG.error("Fail to stop: {}", e, e);
      throw Throwables.propagate(e);
    }
  }

  @Override
  public void run() {
    LOG.info("Starting metrics service");
    Futures.getUnchecked(
      Services.chainStart(zkClientService, metricsCollectionService, resourceReporter));

    LOG.info("Starting runnable: {}", name);
    controller = injector.getInstance(getProgramClass()).run(program, programOpts);
    final SettableFuture<ProgramController.State> state = SettableFuture.create();
    controller.addListener(new AbstractListener() {
      @Override
      public void stopped() {
        state.set(ProgramController.State.STOPPED);
      }

      @Override
      public void error(Throwable cause) {
        LOG.error("Program runner error out.", cause);
        state.setException(cause);
      }
    }, MoreExecutors.sameThreadExecutor());

    runlatch.countDown();
    try {
      state.get();
      LOG.info("Program stopped.");
    } catch (Throwable t) {
      LOG.error("Program terminated due to error.", t);
      throw Throwables.propagate(t);
    }
  }

  @Override
  public void destroy() {
    LOG.info("Releasing resources: {}", name);
    Futures.getUnchecked(
      Services.chainStop(resourceReporter, metricsCollectionService, zkClientService));
    LOG.info("Runnable stopped: {}", name);
  }

  private CommandLine parseArgs(String[] args) {
    Options opts = new Options()
      .addOption(createOption(RunnableOptions.JAR, "Program jar location"))
      .addOption(createOption(RunnableOptions.RUNTIME_ARGS, "Runtime arguments"));

    try {
      return new PosixParser().parse(opts, args);
    } catch (ParseException e) {
      throw Throwables.propagate(e);
    }
  }

  private Option createOption(String opt, String desc) {
    Option option = new Option(opt, true, desc);
    option.setRequired(true);
    return option;
  }

  /**
   * Creates program arguments. It includes all configurations from the specification, excluding hConf and cConf.
   */
  private Arguments createProgramArguments(TwillContext context, Map<String, String> configs) {
    Map<String, String> args = ImmutableMap.<String, String>builder()
      .put(ProgramOptionConstants.INSTANCE_ID, Integer.toString(context.getInstanceId()))
      .put(ProgramOptionConstants.INSTANCES, Integer.toString(context.getInstanceCount()))
      .put(ProgramOptionConstants.RUN_ID, context.getApplicationRunId().getId())
      .putAll(Maps.filterKeys(configs, Predicates.not(Predicates.in(ImmutableSet.of("hConf", "cConf")))))
      .build();

    return new BasicArguments(args);
  }

  // TODO(terence) make this works for different mode
  protected Module createModule(final TwillContext context) {
    return Modules.combine(
      new ConfigModule(cConf, hConf),
      new IOModule(),
      new ZKClientModule(),
      new MetricsClientRuntimeModule().getDistributedModules(),
      new LocationRuntimeModule().getDistributedModules(),
      new DiscoveryRuntimeModule().getDistributedModules(),
      new DataFabricModules().getDistributedModules(),
      new AbstractModule() {
        @Override
        protected void configure() {
          // For Binding queue stuff
          bind(QueueReaderFactory.class).in(Scopes.SINGLETON);

          // For program loading
          install(createProgramFactoryModule());

          // For binding DataSet transaction stuff
          install(new DataFabricFacadeModule());

          bind(ServiceAnnouncer.class).toInstance(new ServiceAnnouncer() {
            @Override
            public Cancellable announce(String serviceName, int port) {
              return context.announce(serviceName, port);
            }
          });
        }
      }
    );
  }

  private Module createProgramFactoryModule() {
    return new PrivateModule() {
      @Override
      protected void configure() {
        bind(LocationFactory.class)
          .annotatedWith(Names.named("program.location.factory"))
          .toInstance(new LocalLocationFactory(new File(System.getProperty("user.dir"))));
        bind(ProgramFactory.class).in(Scopes.SINGLETON);
        expose(ProgramFactory.class);
      }
    };
  }

  /**
   * A private factory for creating instance of Program.
   * It's needed so that we can inject different LocationFactory just for loading program.
   */
  private static final class ProgramFactory {

    private final LocationFactory locationFactory;

    @Inject
    ProgramFactory(@Named("program.location.factory") LocationFactory locationFactory) {
      this.locationFactory = locationFactory;
    }

    public Program create(String path) throws IOException {
      Location location = locationFactory.create(path);
      return Programs.createWithUnpack(location, Files.createTempDir());
    }
  }
}

